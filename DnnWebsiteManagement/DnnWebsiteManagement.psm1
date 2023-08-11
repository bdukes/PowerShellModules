#Requires -Version 3
#Requires -Modules Add-HostFileEntry, AdministratorRole, PKI, SslWebBinding, SqlServer, IISAdministration, Read-Choice
Set-StrictMode -Version:Latest

$www = $env:www
if ($null -eq $www) {
  $inetpub = Join-Path 'C:' -ChildPath:'inetpub';
  $www = Join-Path $inetpub 'wwwroot';
}

function Install-DNNResource {
  [Alias("Install-DNNResources")]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $false, position = 0)]
    [string]$Name
  );

  if ($Name -eq '' -and $PWD.Provider.Name -eq 'FileSystem' -and $PWD.Path.StartsWith($www)) {
    $pathParts = $PWD.Path -split '[\\/]';
    $pathIndex = ($www -split '[\\/]').Length;
    $Name = $pathParts[$pathIndex];
    Write-Verbose "Site name is '$Name'";
  }

  if ($Name -eq '') {
    throw 'You must specify the site name (e.g. dnn.local) if you are not in the website'
  }

  try {
    $result = Invoke-WebRequest "https://$Name/Install/Install.aspx?mode=InstallResources"

    if ($result.StatusCode -ne 200) {

      Write-Warning "There was an error trying to install the resources: Status code $($result.StatusCode)"
      return
    }

    Write-HtmlNode $result.ParsedHtml.documentElement -excludeAttributes -excludeEmptyElements -excludeComments
  }
  catch {
    Write-Warning "There was an error trying to install the resources: $_"
  }

  <#
.SYNOPSIS
    Kicks off any pending extension package installations
.DESCRIPTION
    Starts the Install Resources mode of the installer, installing all extension packages in the Install folder of the website
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local).  If not specified, this is derived from the current folder path
#>
}

function Remove-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name
  );

  Assert-AdministratorRole

  # Allow passing in a path, rather than a name
  $sitePath = Join-Path $www $Name;
  $Name = Split-Path -Path $sitePath -Leaf;

  $hostHeaders = [System.Collections.Generic.HashSet[string]]@($Name);

  $website = Get-IISSite $Name;
  if ($website) {
    foreach ($binding in $website.Bindings) {
      $hostHeader = $binding.bindingInformation.Substring(6) #remove "*:443:" from the beginning of the binding info
      $hostHeaders.Add($hostHeader) | Out-Null;
    }

    foreach ($hostHeader in $hostHeaders) {
      if ($PSCmdlet.ShouldProcess($hostHeader, 'Remove HTTPS Binding')) {
        Remove-SslWebBinding $Name $hostHeader -Confirm:$false -ErrorAction:SilentlyContinue;
      }
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Remove IIS Site')) {
      Remove-IISSite $Name -WhatIf:$WhatIfPreference -Confirm:$false -ErrorAction:SilentlyContinue;
    }
  }

  $serverManager = Get-IISServerManager;
  $appPool = $serverManager.ApplicationPools[$Name];
  if ($appPool) {
    Write-Information "Removing $Name app pool from IIS"

    if ($PSCmdlet.ShouldProcess($Name, 'Remove IIS App Pool')) {
      $appPool.Delete();
      $serverManager.CommitChanges();
    }
  }
  else {
    Write-Information "$Name app pool not found in IIS"
  }

  if (Test-Path $sitePath) {
    if ($PSCmdlet.ShouldProcess($sitePath, "Remove website folder")) {
      Remove-Item $sitePath -Recurse -Force -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }
  else {
    Write-Information "$sitePath does not exist"
  }

  $sqlPath = Join-Path 'SQLSERVER:' 'SQL';
  $localhostSqlPath = Join-Path $sqlPath '(local)';
  $localSqlPath = Join-Path $localhostSqlPath 'DEFAULT';
  $databasesSqlPath = Join-Path $localSqlPath 'Databases';
  $databasePath = Join-Path $databasesSqlPath (ConvertTo-EncodedSqlName $Name);
  if (Test-Path $databasePath) {
    if ($PSCmdlet.ShouldProcess($Name, 'Drop Database')) {
      invokeSql -Query:"ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -Database:master
      invokeSql -Query:"DROP DATABASE [$Name];" -Database:master
    }
  }
  else {
    Write-Information "$Name database not found"
  }

  $loginName = "IIS AppPool\$Name";
  $loginsPath = Join-Path $localSqlPath 'Logins';
  $loginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $loginName);
  if (Test-Path $loginPath) {
    if ($PSCmdlet.ShouldProcess($loginName, 'Drop login')) {
      invokeSql -Query:"DROP LOGIN [$loginName];" -Database:master
    }
  }
  else {
    Write-Information "$loginName database login not found"
  }

  foreach ($hostHeader in $hostHeaders) {
    if ($PSCmdlet.ShouldProcess($hostHeader, 'Remove HOSTS file entry')) {
      Remove-HostFileEntry $hostHeader -WhatIf:$WhatIfPreference -Confirm:$false -ErrorAction:SilentlyContinue;
    }
  }

  <#
.SYNOPSIS
    Destroys a DNN site
.DESCRIPTION
    Destroys a DNN site, removing it from the file system, IIS, and the database
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
#>
}

function Rename-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("oldSiteName")]
    [Alias("oldName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [Alias("newSiteName")]
    [parameter(Mandatory = $true, position = 1)]
    [string]$NewName
  );

  Assert-AdministratorRole

  $serverManager = Get-IISServerManager
  $appPool = $serverManager.ApplicationPools[$Name]
  if ($appPool -and $appPool.State -eq 'Started') {
    if ($PSCmdlet.ShouldProcess("$Name", "Stop IIS app pool")) {
      $appPool.Stop()
      while ($appPool.State -ne 'Stopped') {
        Start-Sleep -m 100
      }
    }
  }

  $oldSitePath = Join-Path $www $Name;
  $newSitePath = Join-Path $www $NewName;
  if (Test-Path $oldSitePath) {
    if ($PSCmdlet.ShouldProcess($oldSitePath, "Rename to $newSitePath")) {
      Rename-Item $oldSitePath $newSitePath -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }
  else {
    Write-Information "$oldSitePath does not exist"
  }

  $newWebsitePath = Join-Path $newSitePath 'Website';
  $website = $serverManager.Sites[$Name];
  $app = $website.Applications['/'];
  $virtualDirectory = $app.VirtualDirectories['/'];
  $virtualDirectory.PhysicalPath = $newWebsitePath;
  if ($PSCmdlet.ShouldProcess("*:80:$Name", "Rename IIS site binding to *:80:$NewName")) {
    Remove-IISSiteBinding -Name:$Name -BindingInformation:"*:80:$Name"
    New-IISSiteBinding -Name:$Name -BindingInformation:"*:80:$NewName" -Protocol:'http'
  }

  if ($PSCmdlet.ShouldProcess("$Name", "Rename IIS site to $NewName")) {
    $website.Name = $NewName;
  }
  if ($PSCmdlet.ShouldProcess("$Name", "Rename IIS app pool to $NewName")) {
    $appPool.Name = $NewName;
    $app.ApplicationPoolName = $NewName;
  }

  $serverManager.CommitChanges();

  $sqlPath = Join-Path 'SQLSERVER:' 'SQL';
  $localhostSqlPath = Join-Path $sqlPath '(local)';
  $localSqlPath = Join-Path $localhostSqlPath 'DEFAULT';
  $databasesSqlPath = Join-Path $localSqlPath 'Databases';
  $databasePath = Join-Path $databasesSqlPath (ConvertTo-EncodedSqlName $Name);
  if (Test-Path $databasePath) {
    if ($PSCmdlet.ShouldProcess("$Name", "Close database connection")) {
      invokeSql -Query:"ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -Database:master
    }
    if ($PSCmdlet.ShouldProcess("$Name", "Rename database to $NewName")) {
      invokeSql -Query:"ALTER DATABASE [$Name] MODIFY NAME = [$NewName];" -Database:master
      invokeSql -Query:"ALTER DATABASE [$NewName] SET MULTI_USER WITH ROLLBACK IMMEDIATE;" -Database:master
    }
  }
  else {
    Write-Information "$Name database not found"
  }

  $oldLoginName = "IIS AppPool\$Name";
  $newLoginName = "IIS AppPool\$NewName";
  $loginsPath = Join-Path $localSqlPath 'Logins';
  $newLoginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $newLoginName);
  if (-not (Test-Path $newLoginPath)) {
    if ($PSCmdlet.ShouldProcess($newLoginName, "Create SQL Server login")) {
      invokeSql -Query:"CREATE LOGIN [$newLoginName] FROM WINDOWS WITH DEFAULT_DATABASE = [$NewName];" -Database:master
    }
  }

  if ($PSCmdlet.ShouldProcess($newLoginName, "Create SQL Server user")) {
    invokeSql -Query:"CREATE USER [$newLoginName] FOR LOGIN [$newLoginName];" -Database:$NewName
  }

  if ($PSCmdlet.ShouldProcess($newLoginName, "Add SQL Server user to db_owner role")) {
    invokeSql -Query:"EXEC sp_addrolemember N'db_owner', N'$newLoginName';" -Database:$NewName
  }

  $ownedRoles = invokeSql -Query:"SELECT p2.name FROM sys.database_principals p1 JOIN sys.database_principals p2 ON p1.principal_id = p2.owning_principal_id WHERE p1.name = '$newLoginName';" -Database:$NewName
  foreach ($roleRow in $ownedRoles) {
    $roleName = $roleRow.name
    if ($PSCmdlet.ShouldProcess("$roleName", "Transfer role ownership to $newLoginName")) {
      invokeSql -Query:"ALTER AUTHORIZATION ON ROLE::[$roleName] TO [$newLoginName];" -Database:$NewName
    }
  }

  if ($PSCmdlet.ShouldProcess($oldLoginName, "Drop SQL Server user")) {
    invokeSql -Query:"DROP USER [$oldLoginName];" -Database:$NewName
  }

  $oldLoginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $oldLoginName);
  if (Test-Path $oldLoginPath) {
    if ($PSCmdlet.ShouldProcess($oldLoginName, "Drop SQL Server login")) {
      invokeSql -Query:"DROP LOGIN [$oldLoginName];" -Database:master
    }
  }
  else {
    Write-Information "$oldLoginName database login not found"
  }

  if ($PSCmdlet.ShouldProcess($newWebsitePath, "Set Modify File Permissions")) {
    Set-ModifyPermission -Directory:$newWebsitePath -Username:$NewName -WhatIf:$WhatIfPreference -Confirm:$false
  }

  $webConfigPath = Join-Path $newWebsitePath 'web.config';
  if ($PSCmdlet.ShouldProcess($webConfigPath, "Update connection string")) {
    [xml]$webConfig = Get-Content $webConfigPath
    $ObjectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $DatabaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')
    $connectionString = "Data Source=.`;Initial Catalog=$NewName`;Integrated Security=true"
    $webConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
    $webConfig.configuration.appSettings.add | Where-Object { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }
    $webConfig.Save($webConfigPath)
  }

  if ($PSCmdlet.ShouldProcess("$NewName", "Replace $Name in portal aliases")) {
    invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$Name', '$NewName')" -Database:$NewName
  }

  if ($PSCmdlet.ShouldProcess("$Name", "Remove HOSTS file entry")) {
    Remove-HostFileEntry $Name -WhatIf:$WhatIfPreference -Confirm:$false
  }
  if ($PSCmdlet.ShouldProcess("$NewName", "Add HOSTS file entry")) {
    Add-HostFileEntry $NewName -WhatIf:$WhatIfPreference -Confirm:$false
  }

  $appPool.Start();

  if ($PSCmdlet.ShouldProcess("https://$NewName", "Open browser")) {
    if (Get-Command -Name:Start-Process -ParameterName:WhatIf -ErrorAction SilentlyContinue) {
      Start-Process -FilePath:https://$NewName -WhatIf:$WhatIfPreference -Confirm:$false;
    }
    else {
      Start-Process -FilePath:https://$NewName;
    }
  }

  <#
.SYNOPSIS
    Renames a DNN site
.DESCRIPTION
    Renames a DNN site in the file system, IIS, and the database
.PARAMETER Name
    The current name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER NewName
    The new name to which the site should be renamed
#>
}

function Restore-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [Alias("siteZip")]
    [parameter(Mandatory = $true, position = 1)]
    [ValidateScript({ if (Test-Path -Path:$_) { $true; } else { throw "$_ file or directory not found" } })]
    [string]$SiteZipPath,

    [Alias("databaseBackup")]
    [parameter(Mandatory = $true, position = 2)]
    [ValidateScript({ if (Test-Path -Path:$_ -PathType:Leaf) { $true; } else { throw "$_ file not found" } })]
    [string]$DatabaseBackupPath,

    [Alias("oldDomain")]
    [parameter(Mandatory = $false)]
    [string]$Domain = '',

    [parameter(Mandatory = $false)]
    [string]$GitRepository = '',

    [parameter(Mandatory = $false)]
    [switch]$Interactive
  );

  $databaseBackupFolder = '';
  $siteZipFile = Get-Item $SiteZipPath
  if ($siteZipFile.Extension -eq '.bak') {
    $SiteZipPath = $DatabaseBackupPath
    $DatabaseBackupPath = $siteZipFile.FullName
  }
  else {
    $DatabaseBackupFile = Get-Item $DatabaseBackupPath;
    if ($DatabaseBackupFile.Extension -ne '.bak') {
      if ($PSCmdlet.ShouldProcess($DatabaseBackupPath, 'Unzip backup file')) {
        $databaseBackupFolder = Join-Path -Path $([System.IO.Path]::GetTempPath()) -ChildPath "dnn-website-management-db-$(Get-Date -Format 'yyyyMMddHHmmss')";
        extractZip -output:$databaseBackupFolder -zipFile:$DatabaseBackupPath;
        $DatabaseBackupPath = Get-Item -Path:"$databaseBackupFolder/*.bak";
      }
    }
  }

  New-DNNSite $Name -SiteZipPath:$SiteZipPath -DatabaseBackupPath:$DatabaseBackupPath -Domain:$Domain -GitRepository:$GitRepository -Interactive:$Interactive;

  $sitePath = Join-Path $www $Name;
  $scriptsDir = Join-Path $sitePath '.dnn-website-management';
  $restoreScript = Join-Path $scriptsDir 'restore-site.ps1';
  if ((Test-Path $restoreScript)) {
    $restoreArgs = @{};
    $restoreCmd = Get-Command $restoreScript;
    if ($restoreCmd.Parameters.ContainsKey('Name')) {
      $restoreArgs['Name'] = $Name;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('siteName')) {
      $restoreArgs['siteName'] = $Name;
    }
    if ($restoreCmd.Parameters.ContainsKey('SiteZipPath')) {
      $restoreArgs['SiteZipPath'] = $SiteZipPath;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('siteZip')) {
      $restoreArgs['siteZip'] = $SiteZipPath;
    }
    if ($restoreCmd.Parameters.ContainsKey('DatabaseBackupPath')) {
      $restoreArgs['DatabaseBackupPath'] = $DatabaseBackupPath;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('databaseBackup')) {
      $restoreArgs['databaseBackup'] = $DatabaseBackupPath;
    }
    if ($restoreCmd.Parameters.ContainsKey('Domain')) {
      $restoreArgs['Domain'] = $Domain;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('oldDomain')) {
      $restoreArgs['oldDomain'] = $Domain;
    }
    if ($restoreCmd.Parameters.ContainsKey('GitRepository')) {
      $restoreArgs['GitRepository'] = $GitRepository;
    }
    if ($restoreCmd.Parameters.ContainsKey('WhatIf')) {
      $restoreArgs['WhatIf'] = $WhatIfPreference;
    }
    if ($restoreCmd.Parameters.ContainsKey('Confirm')) {
      $restoreArgs['Confirm'] = $ConfirmPreference -eq 'Low';
    }
    if ($restoreCmd.Parameters.ContainsKey('Verbose')) {
      $restoreArgs['Verbose'] = $VerbosePreference -eq 'Continue';
    }

    if ($PSCmdlet.ShouldProcess($restoreScript, 'Run restore script') -or $restoreArgs['WhatIf']) {
      & $restoreScript @restoreArgs;
    }
  }

  if ($databaseBackupFolder -and $PSCmdlet.ShouldProcess($databaseBackupFolder, 'Delete database backup folder')) {
    Remove-Item $databaseBackupFolder -Force -Recurse;
  }

  <#
.SYNOPSIS
    Restores a backup of a DNN site
.DESCRIPTION
    Restores a DNN site from a file system zip and database backup
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER SiteZipPath
    The full path to the zip (any format that 7-Zip can expand) of the site's file system, or the full path to a folder with the site's contents
.PARAMETER DatabaseBackupPath
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER Domain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
.PARAMETER GitRepository
    If specified, the git repository at the given URL/path will be cloned into the site's folder
.PARAMETER Interactive
    Whether the cmdlet can prompt the user for additional information (e.g. how to rename additional portal aliases)
#>
}

function Update-DNNSite {
  [Alias("Upgrade-DNNSite")]
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [parameter(Mandatory = $true, position = 1)]
    [string]$SiteZipPath
  );
  try {
    if ($PSCmdlet.ShouldProcess($SiteZipPath, "Extract upgrade package")) {
      extractPackages -Name:$Name -SiteZipPath:$SiteZipPath -ErrorAction Stop;
    }
  }
  catch {
    $PSCmdlet.ThrowTerminatingError($_);
  }

  if ($PSCmdlet.ShouldProcess("https://$Name/Install/Install.aspx?mode=upgrade", "Open browser")) {
    if (Get-Command -Name:Start-Process -ParameterName:WhatIf -ErrorAction SilentlyContinue) {
      Start-Process -FilePath:https://$Name/Install/Install.aspx?mode=upgrade -WhatIf:$WhatIfPreference -Confirm:$false;
    }
    else {
      Start-Process -FilePath:https://$Name/Install/Install.aspx?mode=upgrade;
    }
  }

  <#
.SYNOPSIS
    Upgrades a DNN site
.DESCRIPTION
    Upgrades an existing DNN site using the specified upgrade package
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER SiteZipPath
    The path to the upgrade package zip.
#>
}

function New-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [Alias("siteZip")]
    [parameter(Mandatory = $true, position = 1)]
    [string]$SiteZipPath,

    [string]$ObjectQualifier = '',

    [string]$DatabaseOwner = 'dbo',

    [Alias("databaseBackup")]
    [string]$DatabaseBackupPath = '',

    [Alias("oldDomain")]
    [string]$Domain = '',

    [string]$GitRepository = '',

    [switch]$Interactive
  );

  Assert-AdministratorRole

  $NameExtension = [System.IO.Path]::GetExtension($Name)
  if ($NameExtension -eq '') { $NameExtension = '.local' }

  if ($PSCmdlet.ShouldProcess($Name, 'Extract Package')) {
    try {
      extractPackages -Name:$Name -SiteZip:$SiteZipPath -ErrorAction Stop;
    }
    catch {
      $PSCmdlet.ThrowTerminatingError($_);
    }
  }

  if ($PSCmdlet.ShouldProcess($Name, 'Add HOSTS file entry')) {
    Add-HostFileEntry $Name
  }

  $serverManager = Get-IISServerManager;
  if ($PSCmdlet.ShouldProcess($Name, 'Create IIS App Pool')) {
    $serverManager.ApplicationPools.Add($Name);
    $serverManager.CommitChanges();
  }

  $sitePath = Join-Path $www $Name;
  $websitePath = Join-Path $sitePath 'Website';
  if ($PSCmdlet.ShouldProcess($Name, 'Create IIS Site')) {
    $website = $serverManager.Sites.Add($Name, 'http', "*:80:$Name", $websitePath);
    $website.Applications['/'].ApplicationPoolName = $Name;
    $serverManager.CommitChanges();
  }

  $domains = New-Object System.Collections.Generic.List[System.String]
  $domains.Add($Name)

  if ($PSCmdlet.ShouldProcess($websitePath, 'Set Modify File Permissions')) {
    Set-ModifyPermission -Directory:$websitePath -Username:$Name -WhatIf:$WhatIfPreference -Confirm:$false;
  }

  if ($GitRepository -and $PSCmdlet.ShouldProcess($GitRepository, 'Git clone')) {
    $clonePath = Join-Path $sitePath 'Temp_GitClone';
    git clone $GitRepository $clonePath;

    moveWithProgress -from:$clonePath -to:$sitePath;
    Remove-Item $clonePath -Recurse -Force -Confirm:$false;
  }

  $webConfigPath = Join-Path $websitePath 'web.config';
  [xml]$webConfig = Get-Content $webConfigPath;
  if ($DatabaseBackupPath -eq '') {
    if ($PSCmdlet.ShouldProcess($Name, 'Create Database')) {
      newDnnDatabase $Name -ErrorAction Stop;
    }
    # TODO: create schema if $DatabaseOwner has been passed in
  }
  else {
    if ($PSCmdlet.ShouldProcess($DatabaseBackupPath, 'Restore Database')) {
      restoreDnnDatabase $Name (Get-Item $DatabaseBackupPath).FullName -ErrorAction Stop;
      invokeSql -Query:"ALTER DATABASE [$Name] SET RECOVERY SIMPLE" -Database:master
    }

    $ObjectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $DatabaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')

    if ($PSCmdlet.ShouldProcess($Name, 'Update Portal Aliases')) {
      if ($Domain -ne '') {
        invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$Domain', '$Name')" -Database:$Name
        invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = REPLACE(SettingValue, '$Domain', '$Name') WHERE SettingName = 'DefaultPortalAlias'" -Database:$Name
      }

      $aliases = @(invokeSql -Query:"SELECT PortalID, HTTPAlias FROM $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) WHERE HTTPAlias != '$Name' ORDER BY PortalID, HTTPAlias" -Database:$Name);
      if ($Domain -ne '') {
        $aliasCount = $aliases.Count
        $ProcessManual = $false

        if ($Interactive.IsPresent -and $aliasCount -gt 0) {
          $ProcessManual = Read-BooleanChoice -caption:'Manually Rename Portal Aliases' -message:"Would you like to specify new HTTP aliases for all $aliasCount aliases?" -defaultChoice:$true
        }

        foreach ($aliasRow in $aliases) {
          $alias = $aliasRow.HTTPAlias
          Write-Verbose "Updating $alias"
          $newAlias = renameAlias -Domain:$Domain -Name:$Name -Alias:$alias -NameExtension:$NameExtension;
          if ($ProcessManual) {
            $customAlias = Read-Host -Prompt "New name for Portal ID $($aliasRow.PortalID) alias: '$alias' (default: $newAlias)"
            $newAlias = if ($customAlias) { $customAlias } else { $newAlias }
          }
          if ($PSCmdlet.ShouldProcess($newAlias, 'Rename alias')) {
            invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = '$newAlias' WHERE HTTPAlias = '$alias'" -Database:$Name
            invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '$newAlias' WHERE SettingName = 'DefaultPortalAlias' AND SettingValue = '$alias'" -Database:$Name
          }
        }
      }

      $aliases = invokeSql -Query:"SELECT HTTPAlias FROM $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) ORDER BY PortalID, HTTPAlias" -Database:$Name
      foreach ($aliasRow in $aliases) {
        $aliasInfo = readPortalAlias -Alias:$aliasRow.HTTPAlias;
        $aliasHost = $aliasInfo.host;
        $port = $aliasInfo.port;

        $existingBinding = Get-IISSiteBinding -Name:$Name -BindingInformation:"*:$($port):$aliasHost" -Protocol:http
        if ($null -eq $existingBinding) {
          Write-Verbose "Setting up IIS binding and HOSTS entry for $aliasHost"
          if ($PSCmdlet.ShouldProcess($aliasHost, 'Create IIS Site Binding')) {
            New-IISSiteBinding -Name:$Name -BindingInformation:"*:$($port):$aliasHost" -Protocol:http;
          }
          if ($PSCmdlet.ShouldProcess($aliasHost, 'Add HOSTS file entry')) {
            Add-HostFileEntry $aliasHost -WhatIf:$WhatIfPreference -Confirm:$false;
          }
        }
        else {
          Write-Verbose "IIS binding already exists for $aliasHost"
        }

        $domains.Add($aliasHost)
      }
    }

    if ($ObjectQualifier -ne '') {
      $oq = $ObjectQualifier + '_'
    }
    else {
      $oq = ''
    }

    $sqlPath = Join-Path 'SQLSERVER:' 'SQL';
    $localhostSqlPath = Join-Path $sqlPath '(local)';
    $localSqlPath = Join-Path $localhostSqlPath 'DEFAULT';
    $databasesPath = Join-Path $localSqlPath 'Databases';
    $databasePath = Join-Path $databasesPath (ConvertTo-EncodedSqlName $Name);
    $tablesPath = Join-Path $databasePath 'Tables';
    $catalookSettingsTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}CAT_Settings";
    if ((Test-Path $catalookSettingsTablePath) -and ($PSCmdlet.ShouldProcess($Name, 'Set Catalook to test mode'))) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'CAT_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET PostItems = 0, StorePaymentTypes = 32, StoreCCTypes = 23, CCLogin = '${env:CatalookTestCCLogin}', CCPassword = '${env:CatalookTestCCPassword}', CCMerchantHash = '${env:CatalookTestCCMerchantHash}', StoreCurrencyid = 2, CCPaymentProcessorID = 59, LicenceKey = '${env:CatalookTestLicenseKey}', StoreEmail = '${env:CatalookTestStoreEmail}', Skin = '${env:CatalookTestSkin}', EmailTemplatePackage = '${env:CatalookTestEmailTemplatePackage}', CCTestMode = 1, EnableAJAX = 1" -Database:$Name
    }

    $esmSettingsTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}esm_Settings";
    $esmSettingsColumnsPath = Join-Path $esmSettingsTablePath 'Columns';
    $esmSettingsFattmerchantPath = Join-Path $esmSettingsColumnsPath 'FattmerchantMerchantId';
    if ((Test-Path $esmSettingsFattmerchantPath) -and ($PSCmdlet.ShouldProcess($Name, 'Set FattMerchant to test mode'))) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET MerchantRegistrationStatusId = null, FattmerchantMerchantId = null, FattmerchantApiKey = '${env:FattmerchantTestApiKey}', FattmerchantPaymentsToken = '${env:FattmerchantTestPaymentsToken}' WHERE CCPaymentProcessorID = 185" -Database:$Name
    }

    $esmSettingsStaxPath = Join-Path $esmSettingsColumnsPath 'StaxMerchantId';
    if ((Test-Path $esmSettingsStaxPath) -and ($PSCmdlet.ShouldProcess($Name, 'Set Stax to test mode'))) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET MerchantRegistrationStatusId = null, StaxMerchantId = null, StaxApiKey = '${env:StaxTestApiKey}', StaxPaymentsToken = '${env:StaxTestPaymentsToken}' WHERE CCPaymentProcessorID = 185" -Database:$Name
    }

    $esmParticipantTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}esm_Participant";
    if ((Test-Path $esmParticipantTablePath) -and ($PSCmdlet.ShouldProcess($Name, 'Turn off payment processing for Engage: AMS'))) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Participant' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET PaymentProcessorCustomerId = NULL" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off SMTP for Mandeeps Live Campaign')) {
      $liveCampaignSettingTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}LiveCampaign_Setting";
      if (Test-Path $liveCampaignSettingTablePath) {
        invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_Setting' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SMTPServerMode = 'DNNHostSettings', SendGridAPI = NULL WHERE SMTPServerMode = 'Sendgrid'" -Database:$Name
      }

      $liveCampaignSmtpTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}LiveCampaign_SmtpServer";
      if (Test-Path $liveCampaignSmtpTablePath) {
        invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_SmtpServer' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET Server = 'localhost', Username = '', Password = ''" -Database:$Name
      }
    }

    $desktopModulePath = Join-Path $websitePath 'DesktopModules';
    $engageSportsPath = Join-Path $desktopModulePath 'EngageSports';
    if ((Test-Path $engageSportsPath) -and ($PSCmdlet.ShouldProcess($Name, 'Update Engage: Sports wizard URLs'))) {
      updateWizardUrls $Name
    }

    Write-Information "Setting SMTP to localhost"
    if ($PSCmdlet.ShouldProcess($Name, 'Set SMTP to localhost')) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$Name

      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$Name
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Clear WebServers table')) {
      invokeSql -Query:"TRUNCATE TABLE $(getDnnDatabaseObjectName -objectName:'WebServers' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier)" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off event log buffer')) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'EventLogBuffer'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off search crawler')) {
      invokeSql -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'Schedule' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET Enabled = 0 WHERE TypeFullName = 'DotNetNuke.Professional.SearchCrawler.SearchSpider.SearchSpider, DotNetNuke.Professional.SearchCrawler'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, "Set all passwords to 'pass'")) {
      invokeSql -Query:"UPDATE aspnet_Membership SET PasswordFormat = 0, Password = 'pass'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Watermark site logo(s)')) {
      watermarkLogos $Name $NameExtension
    }

    $appInsightsPath = Join-Path $websitePath 'ApplicationInsights.config';
    if ((Test-Path $appInsightsPath) -and ($PSCmdlet.ShouldProcess($Name, 'Remove Application Insights config'))) {
      Remove-Item $appInsightsPath -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Set connectionString in web.config')) {
    $connectionString = "Data Source=.`;Initial Catalog=$Name`;Integrated Security=true"
    $webConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
    $webConfig.configuration.appSettings.add | Where-Object { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }
    $webConfig.Save($webConfigPath)
  }

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Set objectQualifier and databaseOwner in web.config')) {
    $webConfig.configuration.dotnetnuke.data.providers.add | Where-Object { $_.name -eq 'SqlDataProvider' } | ForEach-Object { $_.objectQualifier = $ObjectQualifier; $_.databaseOwner = $DatabaseOwner }
    $webConfig.Save($webConfigPath)
  }

  $systemWebSection = $webConfig.configuration['system.web'];
  if (-not $systemWebSection) {
    $systemWebSection = $webConfig.configuration.location['system.web'];
  }

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Update web.config to allow short passwords')) {
    $systemWebSection.membership.providers.add | Where-Object { $_.type -eq 'System.Web.Security.SqlMembershipProvider' } | ForEach-Object { $_.minRequiredPasswordLength = '4' }
    $webConfig.Save($webConfigPath)
  }

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Turn on debug mode in web.config')) {
    $systemWebSection.compilation.debug = 'true'
    $webConfig.Save($webConfigPath)
  }

  $loginName = "IIS AppPool\$Name";
  $sqlPath = Join-Path 'SQLSERVER:' 'SQL';
  $localhostSqlPath = Join-Path $sqlPath '(local)';
  $localSqlPath = Join-Path $localhostSqlPath 'DEFAULT';
  $loginsPath = Join-Path $localSqlPath 'Logins';
  $loginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $loginName);
  if ((-not (Test-Path $loginPath)) -and ($PSCmdlet.ShouldProcess($loginName, 'Create SQL Server login'))) {
    invokeSql -Query:"CREATE LOGIN [$loginName] FROM WINDOWS WITH DEFAULT_DATABASE = [$Name];" -Database:master
  }

  if ($PSCmdlet.ShouldProcess($loginName, 'Create SQL Server User')) {
    invokeSql -Query:"CREATE USER [$loginName] FOR LOGIN [$loginName];" -Database:$Name
  }
  if ($PSCmdlet.ShouldProcess($loginName, 'Add db_owner role')) {
    invokeSql -Query:"EXEC sp_addrolemember N'db_owner', N'$loginName';" -Database:$Name
  }

  if ($PSCmdlet.ShouldProcess($Name, 'Add HTTPS bindings')) {
    New-SslWebBinding $Name $domains -WhatIf:$WhatIfPreference -Confirm:$false;
  }

  if ($PSCmdlet.ShouldProcess("https://$Name", 'Open browser')) {
    if (Get-Command -Name:Start-Process -ParameterName:WhatIf -ErrorAction SilentlyContinue) {
      Start-Process -FilePath:https://$Name -WhatIf:$WhatIfPreference -Confirm:$false
    }
    else {
      Start-Process -FilePath:https://$Name;
    }
  }

  <#
.SYNOPSIS
    Creates a DNN site
.DESCRIPTION
    Creates a DNN site, either from a file system zip and database backup, or a new installation
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER SiteZipPath
    The full path to the DNN site zip file or directory
.PARAMETER ObjectQualifier
    The database object qualifier
.PARAMETER DatabaseOwner
    The database schema
.PARAMETER DatabaseBackupPath
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER Domain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
.PARAMETER GitRepository
    If specified, the git repository at the given URL/path will be cloned into the site's folder
.PARAMETER Interactive
    Whether the cmdlet can prompt the user for additional information (e.g. how to rename additional portal aliases)
#>
}

function readPortalAlias($alias) {
  if ($alias -Like '*/*') {
    $split = $alias.Split('/');
    $aliasHost = $split[0];
    $childAlias = $split[1..($split.length - 1)] -join '/';
  }
  else {
    $aliasHost = $alias;
    $childAlias = $null;
  }

  if ($aliasHost -Like '*:*') {
    $split = $aliasHost.Split(':');
    $aliasHost = $split[0];
    $port = $split[1];
  }
  else {
    $port = 80;
  }
  return [pscustomobject]@{host = $aliasHost; port = $port; childAlias = $childAlias };
}

function renameAlias([string]$Domain, [string]$Name, [string]$Alias, [string]$NameExtension) {
  $newAlias = $Alias -replace $Domain, $Name;
  $aliasInfo = readPortalAlias($newAlias);
  $aliasHost = $aliasInfo.host;

  if ($aliasHost -NotLike "*$Name*") {
    $aliasHost = $aliasHost + $NameExtension;
    $newAlias = $aliasHost;
    if ($aliasInfo.port -ne 80) {
      $newAlias = $newAlias + ':' + $aliasInfo.port;
    }

    if ($aliasInfo.childAlias) {
      $newAlias = $newAlias + '/' + $aliasInfo.childAlias;
    }
  }

  return $newAlias;
}

function extractZip {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$output,
    [parameter(Mandatory = $true, position = 1)]
    [string]$zipFile
  );

  Write-Verbose "extracting from $zipFile to $output"
  if (Get-Command '7zG' -ErrorAction SilentlyContinue) {
    $commandName = '7zG'
  }
  elseif (Get-Command '7za' -ErrorAction SilentlyContinue) {
    $commandName = '7za'
  }
  else {
    $commandName = $false
  }
  if ($commandName) {
    try {
      $outputFile = [System.IO.Path]::GetTempFileName()
      if (Get-Command -Name:Start-Process -ParameterName:WhatIf -ErrorAction SilentlyContinue) {
        $process = Start-Process $commandName -ArgumentList "x -y -o`"$output`" -- `"$zipFile`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outputFile -WhatIf:$WhatIfPreference -Confirm:$false;
      }
      else {
        $process = Start-Process $commandName -ArgumentList "x -y -o`"$output`" -- `"$zipFile`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outputFile;
      }

      if ($process.ExitCode -ne 0) {
        $zipLogOutput = Get-Content $outputFile;
        if ($zipLogOutput) {
          Write-Warning $zipLogOutput
        }

        if ($process.ExitCode -eq 1) {
          if ($zipLogOutput) {
            Write-Warning "Non-fatal error extracting $zipFile, see above 7-Zip output"
          }
          else {
            Write-Warning "Non-fatal error extracting $zipFile"
          }
        }
        else {
          if ($zipLogOutput) {
            Write-Error "Error extracting $zipFile, see above 7-Zip output"
          }
          else {
            Write-Error "Error extracting $zipFile"
          }
        }
      }
    }
    finally {
      Remove-Item $outputFile -WhatIf:$false -Confirm:$false;
    }
  }
  else {
    Write-Verbose 'Couldn''t find 7-Zip (try running ''choco install 7zip.commandline''), expanding with the (slower) Expand-Archive cmdlet'
    if (-not (Test-Path $output)) {
      mkdir $output | Out-Null
    }
    Expand-Archive $zipFile -DestinationPath $output
  }
}

function extractPackages {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,
    [parameter(Mandatory = $true, position = 1)]
    [string]$SiteZipPath
  );

  $SiteZipOutputPath = $null;
  $CopyEntireDirectory = $false;
  $sitePath = Join-Path $www $Name;
  if ($SiteZipPath -ne '') {
    if (Test-Path $SiteZipPath -PathType Leaf) {
      if (Test-Path $sitePath -PathType Container) {
        $SiteZipOutputPath = Join-Path $sitePath 'Extracted_Website';
      }
      else {
        $SiteZipOutputPath = Join-Path $sitePath 'Website';
      }

      extractZip $SiteZipOutputPath $SiteZipPath;
      $SiteZipPath = $SiteZipOutputPath

      $unzippedFiles = @(Get-ChildItem $SiteZipOutputPath -Directory)
      if ($unzippedFiles.Length -eq 1) {
        Write-Verbose "Found a single folder in the zip, assuming it's the entire website"
        $SiteZipPath = Join-Path $SiteZipPath $unzippedFiles.Name;
      }
    }

    $binPath = Join-Path $SiteZipPath 'bin'
    $assemblyPath = Join-Path $binPath 'DotNetNuke.dll';
    if (-not (Test-Path $assemblyPath)) {
      $websitePath = Join-Path $SiteZipPath 'Website';
      $binPath = Join-Path $websitePath 'bin';
      $assemblyPath = Join-Path $binPath 'DotNetNuke.dll';
      if (Test-Path $assemblyPath) {
        $CopyEntireDirectory = Test-Path (Join-Path $SiteZipPath '.gitignore');
        if (-not $CopyEntireDirectory) {
          $SiteZipPath = Join-Path $SiteZipPath "Website"
          Write-Verbose "Found a Website folder, adjusting path"
        }
        else {
          Write-Verbose "Found a .gitignore file, assuming this is a development site"
        }
      }
    }
  }

  if ($null -eq $SiteZipPath -or $SiteZipPath -eq '' -or -not (Test-Path $SiteZipPath)) {
    throw "The supplied file $SiteZipPath could not be found, aborting installation"
  }

  $SiteZipPath = (Get-Item $SiteZipPath).FullName
  Write-Information "Extracting DNN site"
  if (Test-Path $SiteZipPath -PathType Leaf) {
    if (Test-Path $sitePath -PathType Container) {
      $SiteZipOutputPath = Join-Path $sitePath 'Extracted_Website';
    }
    else {
      $SiteZipOutputPath = Join-Path $sitePath 'Website';
    }

    extractZip $SiteZipOutputPath $SiteZipPath
    $SiteZipPath = $SiteZipOutputPath
  }

  if ($SiteZipPath -eq $sitePath -or $SiteZipPath -eq (Join-Path $sitePath 'Website')) {
    return;
  }

  if ($CopyEntireDirectory) {
    $to = $sitePath
  }
  else {
    $to = Join-Path $sitePath "Website"
  }
  $from = $SiteZipPath


  if ($SiteZipOutputPath) {
    moveWithProgress -from:$from -to:$to;
    Remove-Item $SiteZipOutputPath -Force -Recurse -Confirm:$false;
  }
  else {
    copyWithProgress -from:$from -to:$to;
  }
}

function copyWithProgress($from, $to) {
  processFilesWithProgress `
    -from:$from `
    -to:$to `
    -process: { param($source, $destination); Copy-Item $source $destination -Force -Confirm:$false; } `
    -activity:"Copying files to $to" `
    -status:'Copying…';
}

function moveWithProgress($from, $to) {
  processFilesWithProgress `
    -from:$from `
    -to:$to `
    -process: { param($source, $destination); Move-Item $source $destination -Force -Confirm:$false; } `
    -activity:"Moving files to $to" `
    -status:'Moving…';
}

function processFilesWithProgress($from, $to, [scriptblock]$process, $activity, $status) {
  $filesToCopy = Get-ChildItem $from -Recurse -File -Force;
  $totalCount = $filesToCopy.Count;
  $progressCount = 0;
  Write-Progress -Activity:$activity -Status:$status -PercentComplete 0;
  foreach ($file in $filesToCopy) {
    $progressCount += 1;
    $relativePath = $file.FullName -replace [regex]::escape($from), '';
    $destination = Join-Path $to $relativePath;
    Write-Progress -Activity:$activity -Status:$status -PercentComplete ($progressCount / $totalCount * 100) -CurrentOperation:$destination;
    $directory = Split-Path $destination;
    $baseDirectory = Split-Path $directory;
    $directoryName = Split-Path $directory -Leaf;
    New-Item -Path:$baseDirectory -Name:$directoryName -ItemType:Directory -Force -Confirm:$false | Out-Null;
    Invoke-Command -ScriptBlock:$process -ArgumentList:@($file.FullName, $destination);
  }

  Write-Progress -Activity:$activity -PercentComplete 100 -Completed;
}

$sqlModuleHasEncryptParam = $null -ne (Get-Command Invoke-Sqlcmd).Parameters['Encrypt'];
function invokeSql {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Query,
    [parameter(Mandatory = $true, position = 1)]
    [string]$Database
  );

  if ($sqlModuleHasEncryptParam) {
    Invoke-Sqlcmd -Query:$Query -Database:$Database -Encrypt:Optional;
  }
  else {
    Invoke-Sqlcmd -Query:$Query -Database:$Database -EncryptConnection:$false;
  }
}


function newDnnDatabase {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name
  );

  invokeSql -Query:"CREATE DATABASE [$Name];" -Database:master;
  invokeSql -Query:"ALTER DATABASE [$Name] SET RECOVERY SIMPLE;" -Database:master;
}

function restoreDnnDatabase {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,
    [parameter(Mandatory = $true, position = 1)]
    [string]$DatabaseBackupPath
  );

  $softwareRegistryPath = Join-Path 'HKLM:' 'SOFTWARE';
  $microsoftRegistryPath = Join-Path $softwareRegistryPath 'Microsoft';
  $sqlServerRegistryPath = Join-Path $microsoftRegistryPath 'Microsoft SQL Server';
  if (Test-Path $sqlServerRegistryPath) {
    $defaultInstanceKey = Get-ChildItem $sqlServerRegistryPath | Where-Object { $_.Name -match 'MSSQL\d+\.MSSQLSERVER$' } | Select-Object
    if ($defaultInstanceKey) {
      $defaultInstanceInfoPath = Join-Path $defaultInstanceKey.PSPath 'MSSQLServer'
      $backupDir = $(Get-ItemProperty -path:$defaultInstanceInfoPath -name:BackupDirectory).BackupDirectory
      if ($backupDir) {
        $sqlAcl = Get-Acl $backupDir
        Set-Acl $DatabaseBackupPath $sqlAcl -Confirm:$false;
      }
      else {
        Write-Warning 'Unable to find SQL Server backup directory, backup file will not have ACL permissions set'
      }
    }
    else {
      Write-Warning 'Unable to find SQL Server info in registry, backup file will not have ACL permissions set'
    }
  }
  else {
    Write-Warning 'Unable to find SQL Server info in registry, backup file will not have ACL permissions set'
  }

  $dbRestoreFile = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile;
  $dbRestoreLog = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile;

  $logicalDataFileName = $Name;
  $logicalLogFileName = $Name;

  #based on http://redmondmag.com/articles/2009/12/21/automated-restores.aspx
  $server = New-Object Microsoft.SqlServer.Management.Smo.Server('(local)');
  $dbRestore = New-Object Microsoft.SqlServer.Management.Smo.Restore;
  $dbRestore.Devices.AddDevice($DatabaseBackupPath, [Microsoft.SqlServer.Management.Smo.DeviceType]::File)
  foreach ($file in $dbRestore.ReadFileList($server)) {
    switch ($file.Type) {
      'D' { $logicalDataFileName = $file.LogicalName }
      'L' { $logicalLogFileName = $file.LogicalName }
    }
  }

  $dbRestoreFile.LogicalFileName = $logicalDataFileName;
  $dbRestoreFile.PhysicalFileName = Join-Path $server.Information.MasterDBPath ($Name + '_Data.mdf');
  $dbRestoreLog.LogicalFileName = $logicalLogFileName;
  $dbRestoreLog.PhysicalFileName = Join-Path $server.Information.MasterDBLogPath ($Name + '_Log.ldf');

  Restore-SqlDatabase -ReplaceDatabase -Database:$Name -RelocateFile:@($dbRestoreFile, $dbRestoreLog) -BackupFile:$DatabaseBackupPath -ServerInstance:'(local)' -Confirm:$false;
}

function getDnnDatabaseObjectName {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$objectName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$DatabaseOwner,
    [parameter(Mandatory = $false, position = 2)]
    [string]$ObjectQualifier
  );

  if ($ObjectQualifier -ne '') { $ObjectQualifier += '_' }
  return $DatabaseOwner + ".[$ObjectQualifier$objectName]"
}

function updateWizardUrls {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name
  );

  $uri = $null
  $sitePath = Join-Path $www $Name;
  $websitePath = Join-Path $sitePath 'Website';
  $desktopModulePath = Join-Path $websitePath 'DesktopModules';
  $wizardPath = Join-Path $desktopModulePath 'EngageSports';
  foreach ($wizardManifest in (Get-ChildItem $wizardPath -Include:'*Wizard*.xml')) {
    [xml]$wizardXml = Get-Content $wizardManifest
    foreach ($urlNode in $wizardXml.GetElementsByTagName("NextUrl")) {
      if ([System.Uri]::TryCreate([string]$urlNode.InnerText, [System.UriKind]::Absolute, [ref] $uri)) {
        $urlNode.InnerText = "https://$Name" + $uri.AbsolutePath
      }
    }

    $wizardXml.Save($wizardManifest.FullName)
  }
}

function watermarkLogos {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,
    [parameter(Mandatory = $true, position = 1)]
    [string]$NameExtension
  );

  if (Get-Command 'gm.exe' -ErrorAction:SilentlyContinue) {
    $cmd = 'gm.exe'
    $subCmd = 'mogrify'
  }
  elseif (Get-Command 'mogrify' -ErrorAction:SilentlyContinue) {
    $cmd = 'mogrify'
    $subCmd = ''
  }
  else {
    Write-Warning "Could not watermark logos, because neither GrapgicsMagick nor ImageMagick's mogrify command could not be found"
    return
  }

  $sitePath = Join-Path $www $Name;
  $websitePath = Join-Path $sitePath 'Website';
  $logos = invokeSql -Query:"SELECT HomeDirectory + N'/' + LogoFile AS Logo FROM $(getDnnDatabaseObjectName -objectName:'Vw_Portals' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) WHERE LogoFile IS NOT NULL" -Database:$Name
  $watermarkText = $NameExtension.Substring(1)
  foreach ($logo in $logos) {
    $logoFile = Join-Path $websitePath $logo.Logo.Replace('/', '\');
    & $cmd $subCmd -font Arial -pointsize 60 -draw "gravity Center fill #00ff00 text 0,0 $watermarkText" -draw "gravity NorthEast fill #ff00ff text 0,0 $watermarkText" -draw "gravity SouthWest fill #00ffff text 0,0 $watermarkText" -draw "gravity NorthWest fill #ff0000 text 0,0 $watermarkText" -draw "gravity SouthEast fill #0000ff text 0,0 $watermarkText" $logoFile
  }
}

Export-ModuleMember Install-DNNResource
Export-ModuleMember Remove-DNNSite
Export-ModuleMember Rename-DNNSite
Export-ModuleMember New-DNNSite
Export-ModuleMember Update-DNNSite
Export-ModuleMember Restore-DNNSite
