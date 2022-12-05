#Requires -Version 3
#Requires -Modules Add-HostFileEntry, AdministratorRole, PKI, SslWebBinding, SqlServer, IISAdministration
Set-StrictMode -Version:Latest

$defaultDNNVersion = $env:DnnWebsiteManagement_DefaultVersion
if ($null -eq $defaultDNNVersion) { $defaultDNNVersion = '9.10.2' }

$defaultIncludeSource = $env:DnnWebsiteManagement_DefaultIncludeSource
if ($defaultIncludeSource -eq 'false') { $defaultIncludeSource = $false }
elseif ($defaultIncludeSource -eq 'no') { $defaultIncludeSource = $false }
elseif ($defaultIncludeSource -eq '0') { $defaultIncludeSource = $false }
elseif ($defaultIncludeSource -eq '') { $defaultIncludeSource = $false }
elseif ($null -eq $defaultIncludeSource) { $defaultIncludeSource = $false }
else { $defaultIncludeSource = $true }

$www = $env:www
if ($null -eq $www) {
  $inetpub = Join-Path 'C:' -ChildPath:'inetpub';
  $www = Join-Path $inetpub 'wwwroot';
}

Add-Type -TypeDefinition @"
   public enum DnnProduct
   {
      DnnPlatform,
      EvoqContent,
      EvoqContentEnterprise,
      EvoqEngage,
   }
"@

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

  #TODO: remove certificate
  if ($PSCmdlet.ShouldProcess($Name, 'Remove HTTPS Binding')) {
    Remove-SslWebBinding $Name -Confirm:$false;
  }

  $website = Get-IISSite $Name;
  if ($website) {
    foreach ($binding in $website.Bindings) {
      if ($binding.sslFlags -eq 1) {
        $hostHeader = $binding.bindingInformation.Substring(6) #remove "*:443:" from the beginning of the binding info
        if ($PSCmdlet.ShouldProcess($hostHeader, 'Remove HTTPS Binding')) {
          Remove-SslWebBinding $Name $hostHeader -Confirm:$false;
        }
      }
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Remove IIS Site')) {
      Remove-IISSite $Name -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }

  $serverManager = Get-IISServerManager
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

  $sitePath = Join-Path $www $Name;
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
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
      Invoke-Sqlcmd -Query:"DROP DATABASE [$Name];" -ServerInstance:. -Database:master
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
      Invoke-Sqlcmd -Query:"DROP LOGIN [$loginName];" -Database:master
    }
  }
  else {
    Write-Information "$loginName database login not found"
  }

  #TODO: remove all host entries added during restore
  if ($PSCmdlet.ShouldProcess($Name, 'Remove HOSTS file entry')) {
    Remove-HostFileEntry $Name -WhatIf:$WhatIfPreference -Confirm:$false;
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
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
    }
    if ($PSCmdlet.ShouldProcess("$Name", "Rename database to $NewName")) {
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$Name] MODIFY NAME = [$NewName];" -ServerInstance:. -Database:master
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$NewName] SET MULTI_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
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
      Invoke-Sqlcmd -Query:"CREATE LOGIN [$newLoginName] FROM WINDOWS WITH DEFAULT_DATABASE = [$NewName];" -Database:master
    }
  }

  if ($PSCmdlet.ShouldProcess($newLoginName, "Create SQL Server user")) {
    Invoke-Sqlcmd -Query:"CREATE USER [$newLoginName] FOR LOGIN [$newLoginName];" -Database:$NewName
  }

  if ($PSCmdlet.ShouldProcess($newLoginName, "Add SQL Server user to db_owner role")) {
    Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'$newLoginName';" -Database:$NewName
  }

  $ownedRoles = Invoke-SqlCmd -Query:"SELECT p2.name FROM sys.database_principals p1 JOIN sys.database_principals p2 ON p1.principal_id = p2.owning_principal_id WHERE p1.name = '$newLoginName';" -Database:$NewName
  foreach ($roleRow in $ownedRoles) {
    $roleName = $roleRow.name
    if ($PSCmdlet.ShouldProcess("$roleName", "Transfer role ownership to $newLoginName")) {
      Invoke-SqlCmd -Query:"ALTER AUTHORIZATION ON ROLE::[$roleName] TO [$newLoginName];" -Database:$NewName
    }
  }

  if ($PSCmdlet.ShouldProcess($oldLoginName, "Drop SQL Server user")) {
    Invoke-Sqlcmd -Query:"DROP USER [$oldLoginName];" -Database:$NewName
  }

  $oldLoginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $oldLoginName);
  if (Test-Path $oldLoginPath) {
    if ($PSCmdlet.ShouldProcess($oldLoginName, "Drop SQL Server login")) {
      Invoke-Sqlcmd -Query:"DROP LOGIN [$oldLoginName];" -Database:master
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
    Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$Name', '$NewName')" -Database:$NewName
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

    [Alias("sourceVersion")]
    [parameter(Mandatory = $false)]
    [string]$Version = '',

    [Alias("oldDomain")]
    [parameter(Mandatory = $false)]
    [string]$Domain = '',

    [parameter(Mandatory = $false)]
    [switch]$IncludeSource = $defaultIncludeSource,

    [parameter(Mandatory = $false)]
    [string]$GitRepository = ''
  );

  $siteZipFile = Get-Item $SiteZipPath
  if ($siteZipFile.Extension -eq '.bak') {
    $SiteZipPath = $DatabaseBackupPath
    $DatabaseBackupPath = $siteZipFile.FullName
  }

  $IncludeSource = $IncludeSource -or $Version -ne ''
  New-DNNSite $Name -SiteZipPath:$SiteZipPath -DatabaseBackupPath:$DatabaseBackupPath -Version:$Version -IncludeSource:$IncludeSource -Domain:$Domain -GitRepository:$GitRepository;

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
    if ($restoreCmd.Parameters.ContainsKey('Version')) {
      $restoreArgs['Version'] = $Version;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('sourceVersion')) {
      $restoreArgs['sourceVersion'] = $Version;
    }
    if ($restoreCmd.Parameters.ContainsKey('Domain')) {
      $restoreArgs['Domain'] = $Domain;
    }
    elseif ($restoreCmd.Parameters.ContainsKey('oldDomain')) {
      $restoreArgs['oldDomain'] = $Domain;
    }
    if ($restoreCmd.Parameters.ContainsKey('IncludeSource')) {
      $restoreArgs['IncludeSource'] = $IncludeSource;
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
.PARAMETER Version
    If specified, the DNN source for this version will be included with the site
.PARAMETER Domain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
.PARAMETER GitRepository
    If specified, the git repository at the given URL/path will be cloned into the site's folder
#>
}

function Update-DNNSite {
  [Alias("Upgrade-DNNSite")]
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [parameter(Mandatory = $false, position = 1)]
    [string]$Version = $defaultDNNVersion,

    [parameter(Mandatory = $false, position = 2)]
    [DnnProduct]$Product = [DnnProduct]::DnnPlatform,

    [switch]$IncludeSource = $defaultIncludeSource
  );
  try {
    if ($PSCmdlet.ShouldProcess($Name, "Extract $Version upgrade package")) {
      extractPackages -Name:$Name -Version:$Version -Product:$Product -IncludeSource:$IncludeSource -UseUpgradePackage -ErrorAction Stop;
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
    Upgrades an existing DNN site to the specified version
.PARAMETER Name
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER Version
    The version of DNN to which the site should be upgraded.  Defaults to $defaultDNNVersion
.PARAMETER Product
    The DNN product for the upgrade package.  Defaults to DnnPlatform
.PARAMETER IncludeSource
    Whether to include the DNN source
#>
}

function New-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Alias("siteName")]
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name,

    [parameter(Mandatory = $false, position = 1)]
    [string]$Version = $defaultDNNVersion,

    [parameter(Mandatory = $false, position = 2)]
    [DnnProduct]$Product = [DnnProduct]::DnnPlatform,

    [switch]$IncludeSource = $defaultIncludeSource,

    [string]$ObjectQualifier = '',

    [string]$DatabaseOwner = 'dbo',

    [Alias("siteZip")]
    [string]$SiteZipPath = '',

    [Alias("databaseBackup")]
    [string]$DatabaseBackupPath = '',

    [Alias("oldDomain")]
    [string]$Domain = '',

    [string]$GitRepository = ''
  );

  Assert-AdministratorRole

  $NameExtension = [System.IO.Path]::GetExtension($Name)
  if ($NameExtension -eq '') { $NameExtension = '.local' }

  if ($PSCmdlet.ShouldProcess($Name, 'Extract Package')) {
    try {
      extractPackages -Name:$Name -Version:$Version -Product:$Product -IncludeSource:$IncludeSource -SiteZip:$SiteZipPath -ErrorAction Stop;
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
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$Name] SET RECOVERY SIMPLE"
    }

    $ObjectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $DatabaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')

    if ($Domain -ne '') {
      if ($PSCmdlet.ShouldProcess($Name, 'Update Portal Aliases')) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$Domain', '$Name')" -Database:$Name
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = REPLACE(SettingValue, '$Domain', '$Name') WHERE SettingName = 'DefaultPortalAlias'" -Database:$Name
      }

      $aliases = Invoke-Sqlcmd -Query:"SELECT HTTPAlias FROM $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) WHERE HTTPAlias != '$Name'" -Database:$Name
      foreach ($aliasRow in $aliases) {
        $alias = $aliasRow.HTTPAlias
        Write-Verbose "Updating $alias"
        if ($alias -Like '*/*') {
          $split = $alias.Split('/')
          $aliasHost = $split[0]
          $childAlias = $split[1..($split.length - 1)] -join '/'
        }
        else {
          $aliasHost = $alias
          $childAlias = $null
        }

        if ($aliasHost -Like '*:*') {
          $split = $aliasHost.Split(':')
          $aliasHost = $split[0]
          $port = $split[1]
        }
        else {
          $port = 80
        }

        if ($aliasHost -NotLike "*$Name*") {
          $aliasHost = $aliasHost + $NameExtension
          $newAlias = $aliasHost
          if ($port -ne 80) {
            $newAlias = $newAlias + ':' + $port
          }

          if ($childAlias) {
            $newAlias = $newAlias + '/' + $childAlias
          }

          if ($PSCmdlet.ShouldProcess($newAlias, 'Rename alias')) {
            Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET HTTPAlias = '$newAlias' WHERE HTTPAlias = '$alias'" -Database:$Name
          }
        }

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
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'CAT_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET PostItems = 0, StorePaymentTypes = 32, StoreCCTypes = 23, CCLogin = '${env:CatalookTestCCLogin}', CCPassword = '${env:CatalookTestCCPassword}', CCMerchantHash = '${env:CatalookTestCCMerchantHash}', StoreCurrencyid = 2, CCPaymentProcessorID = 59, LicenceKey = '${env:CatalookTestLicenseKey}', StoreEmail = '${env:CatalookTestStoreEmail}', Skin = '${env:CatalookTestSkin}', EmailTemplatePackage = '${env:CatalookTestEmailTemplatePackage}', CCTestMode = 1, EnableAJAX = 1" -Database:$Name
    }

    $esmSettingsTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}esm_Settings";
    $esmSettingsColumnsPath = Join-Path $esmSettingsTablePath 'Columns';
    $esmSettingsFattmerchantPath = Join-Path $esmSettingsColumnsPath 'FattmerchantMerchantId';
    if ((Test-Path $esmSettingsFattmerchantPath) -and ($PSCmdlet.ShouldProcess($Name, 'Set FattMerchant to test mode'))) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET MerchantRegistrationStatusId = null, FattmerchantMerchantId = null, FattmerchantApiKey = '${env:FattmerchantTestApiKey}', FattmerchantPaymentsToken = '${env:FattmerchantTestPaymentsToken}' WHERE CCPaymentProcessorID = 185" -Database:$Name
    }

    $esmSettingsStaxPath = Join-Path $esmSettingsColumnsPath 'StaxMerchantId';
    if ((Test-Path $esmSettingsStaxPath) -and ($PSCmdlet.ShouldProcess($Name, 'Set Stax to test mode'))) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Settings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET MerchantRegistrationStatusId = null, StaxMerchantId = null, StaxApiKey = '${env:StaxTestApiKey}', StaxPaymentsToken = '${env:StaxTestPaymentsToken}' WHERE CCPaymentProcessorID = 185" -Database:$Name
    }

    $esmParticipantTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}esm_Participant";
    if ((Test-Path $esmParticipantTablePath) -and ($PSCmdlet.ShouldProcess($Name, 'Turn off payment processing for Engage: AMS'))) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Participant' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET PaymentProcessorCustomerId = NULL" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off SMTP for Mandeeps Live Campaign')) {
      $liveCampaignSettingTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}LiveCampaign_Setting";
      if (Test-Path $liveCampaignSettingTablePath) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_Setting' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SMTPServerMode = 'DNNHostSettings', SendGridAPI = NULL WHERE SMTPServerMode = 'Sendgrid'" -Database:$Name
      }

      $liveCampaignSmtpTablePath = Join-Path $tablesPath "$DatabaseOwner.${oq}LiveCampaign_SmtpServer";
      if (Test-Path $liveCampaignSmtpTablePath) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_SmtpServer' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET Server = 'localhost', Username = '', Password = ''" -Database:$Name
      }
    }

    $desktopModulePath = Join-Path $websitePath 'DesktopModules';
    $engageSportsPath = Join-Path $desktopModulePath 'EngageSports';
    if ((Test-Path $engageSportsPath) -and ($PSCmdlet.ShouldProcess($Name, 'Update Engage: Sports wizard URLs'))) {
      updateWizardUrls $Name
    }

    Write-Information "Setting SMTP to localhost"
    if ($PSCmdlet.ShouldProcess($Name, 'Set SMTP to localhost')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$Name

      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$Name
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Clear WebServers table')) {
      Invoke-Sqlcmd -Query:"TRUNCATE TABLE $(getDnnDatabaseObjectName -objectName:'WebServers' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier)" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off event log buffer')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET SettingValue = 'N' WHERE SettingName = 'EventLogBuffer'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Turn off search crawler')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'Schedule' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) SET Enabled = 0 WHERE TypeFullName = 'DotNetNuke.Professional.SearchCrawler.SearchSpider.SearchSpider, DotNetNuke.Professional.SearchCrawler'" -Database:$Name
    }

    if ($PSCmdlet.ShouldProcess($Name, "Set all passwords to 'pass'")) {
      Invoke-Sqlcmd -Query:"UPDATE aspnet_Membership SET PasswordFormat = 0, Password = 'pass'" -Database:$Name
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

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Update web.config to allow short passwords')) {
    $webConfig.configuration['system.web'].membership.providers.add | Where-Object { $_.type -eq 'System.Web.Security.SqlMembershipProvider' } | ForEach-Object { $_.minRequiredPasswordLength = '4' }
    $webConfig.Save($webConfigPath)
  }

  if ($PSCmdlet.ShouldProcess($webConfigPath, 'Turn on debug mode in web.config')) {
    $webConfig.configuration['system.web'].compilation.debug = 'true'
    $webConfig.Save($webConfigPath)
  }

  $loginName = "IIS AppPool\$Name";
  $sqlPath = Join-Path 'SQLSERVER:' 'SQL';
  $localhostSqlPath = Join-Path $sqlPath '(local)';
  $localSqlPath = Join-Path $localhostSqlPath 'DEFAULT';
  $loginsPath = Join-Path $localSqlPath 'Logins';
  $loginPath = Join-Path $loginsPath (ConvertTo-EncodedSqlName $loginName);
  if ((-not (Test-Path $loginPath)) -and ($PSCmdlet.ShouldProcess($loginName, 'Create SQL Server login'))) {
    Invoke-Sqlcmd -Query:"CREATE LOGIN [$loginName] FROM WINDOWS WITH DEFAULT_DATABASE = [$Name];" -Database:master
  }

  if ($PSCmdlet.ShouldProcess($loginName, 'Create SQL Server User')) {
    Invoke-Sqlcmd -Query:"CREATE USER [$loginName] FOR LOGIN [$loginName];" -Database:$Name
  }
  if ($PSCmdlet.ShouldProcess($loginName, 'Add db_owner role')) {
    Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'$loginName';" -Database:$Name
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
.PARAMETER Version
    The DNN version  Defaults to $defaultDnnVersion
.PARAMETER Product
    The DNN product.  Defaults to DnnPlatform
.PARAMETER IncludeSource
    Whether to include the DNN source files
.PARAMETER ObjectQualifier
    The database object qualifier
.PARAMETER DatabaseOwner
    The database schema
.PARAMETER DatabaseBackupPath
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER Version
    If specified, the DNN source for this version will be included with the site
.PARAMETER Domain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
.PARAMETER GitRepository
    If specified, the git repository at the given URL/path will be cloned into the site's folder
#>
}

function getPackageName([System.Version]$Version, [DnnProduct]$Product) {
  $72version = New-Object System.Version("7.2")
  $74version = New-Object System.Version("7.4")
  if ($Version -lt $72version) {
    $ProductPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DotNetNuke_Community"
      [DnnProduct]::EvoqContent           = "DotNetNuke_Professional"
      [DnnProduct]::EvoqContentEnterprise = "DotNetNuke_Enterprise"
      [DnnProduct]::EvoqEngage            = "Evoq_Social"
    }
  }
  elseif ($Version -lt $74version) {
    $ProductPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DNN_Platform"
      [DnnProduct]::EvoqContent           = "Evoq_Content"
      [DnnProduct]::EvoqContentEnterprise = "Evoq_Enterprise"
      [DnnProduct]::EvoqEngage            = "Evoq_Social"
    }
  }
  else {
    $ProductPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DNN_Platform"
      [DnnProduct]::EvoqContent           = "Evoq_Content_Basic"
      [DnnProduct]::EvoqContentEnterprise = "Evoq_Content"
      [DnnProduct]::EvoqEngage            = "Evoq_Engage"
    }
  }
  return $ProductPackageNames.Get_Item($Product)
}

function findPackagePath([System.Version]$Version, [DnnProduct]$Product, [string]$type) {
  $dnnSoftRoot = Join-Path $env:soft 'DNN';
  $packagesRoot = Join-Path $dnnSoftRoot 'Versions';
  $majorVersion = $Version.Major
  switch ($Product) {
    DnnPlatform { $packagesFolder = (Join-Path $packagesRoot "DotNetNuke $majorVersion"); break; }
    EvoqContent { $packagesFolder = (Join-Path $packagesRoot "Evoq Content Basic"); break; }
    EvoqContentEnterprise { $packagesFolder = (Join-Path $packagesRoot "Evoq Content"); break; }
    EvoqEngage { $packagesFolder = (Join-Path $packagesRoot "Evoq Engage"); break; }
  }

  $packageName = getPackageName $Version $Product

  $formattedVersion = $Version.Major.ToString('0') + '.' + $Version.Minor.ToString('0') + '.' + $Version.Build.ToString('0')
  $package = Join-Path $packagesFolder "${packageName}_${formattedVersion}*_${type}.zip" -Resolve | Get-Item;
  if ($null -eq $package) {
    $formattedVersion = $Version.Major.ToString('0#') + '.' + $Version.Minor.ToString('0#') + '.' + $Version.Build.ToString('0#')
    $package = Join-Path $packagesFolder "${packageName}_${formattedVersion}*_${type}.zip" -Resolve | Get-Item;
  }

  if (($null -eq $package) -and ($Product -ne [DnnProduct]::DnnPlatform)) {
    return findPackagePath -Version:$Version -Product:DnnPlatform -type:$type
  }
  elseif ($null -eq $package) {
    return $null
  }
  else {
    return $package.FullName
  }
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
    [parameter(Mandatory = $false, position = 1)]
    [string]$Version,
    [parameter(Mandatory = $true, position = 2)]
    [DnnProduct]$Product = [DnnProduct]::DnnPlatform,
    [switch]$IncludeSource = $defaultIncludeSource,
    [string]$SiteZipPath = '',
    [switch]$useUpgradePackage
  );

  $SiteZipOutputPath = $null;
  $CopyEntireDirectory = $false;
  $sitePath = Join-Path $www $Name;
  if ($SiteZipPath -ne '') {
    if (Test-Path $SiteZipPath -PathType Leaf) {
      $SiteZipOutputPath = Join-Path $sitePath 'Extracted_Website';
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
        $CopyEntireDirectory = Test-Path (Join-Path $SiteZipPath .gitignore);
        if (-not $CopyEntireDirectory) {
          $SiteZipPath = Join-Path $SiteZipPath "Website"
          Write-Verbose "Found a Website folder, adjusting path"
        }
        else {
          Write-Verbose "Found a .gitignore file, assuming this is a development site"
        }
      }
    }

    $Version = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Version
    Write-Verbose "Found version $Version of DotNetNuke.dll"
  }
  elseif ($null -eq $env:soft) {
    throw 'You must set the environment variable `soft` to the path that contains your DNN install packages'
  }

  if ($Version -eq '') {
    $Version = $defaultDNNVersion
  }

  $Version = New-Object System.Version($Version)
  Write-Verbose "Version is $Version"

  if ($IncludeSource -eq $true) {
    Write-Information "Extracting DNN $Version source"
    $sourcePath = findPackagePath -Version:$Version -Product:$Product -type:'Source'
    Write-Verbose "Source Path is $sourcePath"
    if ($null -eq $sourcePath -or $sourcePath -eq '' -or -not (Test-Path $sourcePath)) {
      Write-Error "Fallback source package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Extract DNN $Version source" -CategoryTargetName:$sourcePath -TargetObject:$sourcePath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    }

    $sitePath = Join-Path $www $Name;
    Write-Verbose "extracting from $sourcePath to $sitePath"
    extractZip $sitePath "$sourcePath"
    $platformPath = Join-Path $sitePath "Platform";
    if (Test-Path (Join-Path $platformPath "Website") -PathType Container) {
      Copy-Item "$platformPath/*" $sitePath -Force -Recurse
      Remove-Item $platformPath -Force -Recurse
    }

    Write-Information "Copying DNN $Version source symbols into install directory"
    $symbolsPath = findPackagePath -Version:$Version -Product:$Product -type:'Symbols'
    Write-Verbose "Symbols Path is $sourcePath"
    if ($null -eq $symbolsPath -or $symbolsPath -eq '' -or -not (Test-Path $symbolsPath)) {
      Write-Error "Fallback symbols package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Copy DNN $Version source symbols" -CategoryTargetName:$symbolsPath -TargetObject:$symbolsPath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    }

    $websitePath = Join-Path $sitePath 'Website';
    $installPath = Join-Path $websitePath 'Install';
    $moduleInstallPath = Join-Path $installPath 'Module';
    Write-Verbose "cp $symbolsPath $moduleInstallPath"
    Copy-Item $symbolsPath $moduleInstallPath

    Write-Information "Updating site URL in sln files"
    Get-ChildItem -Path:$sitePath -Include:'*.sln' | ForEach-Object {
      $slnContent = (Get-Content $_);
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Community"', "`"https://$Name`"";
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Professional"', "`"https://$Name`"";
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Enterprise"', "`"https://$Name`"";
      $slnContent = $slnContent -replace '"http://localhost/DNN_Platform"', "`"https://$Name`""; # DNN 7.1.2+
      Set-Content $_ $slnContent;
    }
  }

  if ($SiteZipPath -eq '') {
    if ($useUpgradePackage) {
      $SiteZipPath = findPackagePath -Version:$Version -Product:$Product -type:'Upgrade'
    }
    else {
      $SiteZipPath = findPackagePath -Version:$Version -Product:$Product -type:'Install'
    }

    if ($null -eq $SiteZipPath -or $SiteZipPath -eq '' -or -not (Test-Path $SiteZipPath)) {
      throw "The package for $Product $Version could not be found, aborting installation"
    }
  }
  elseif ($null -eq $SiteZipPath -or $SiteZipPath -eq '' -or -not (Test-Path $SiteZipPath)) {
    throw "The supplied file $SiteZipPath could not be found, aborting installation"
  }

  $SiteZipPath = (Get-Item $SiteZipPath).FullName
  Write-Information "Extracting DNN site"
  if (-not (Test-Path $SiteZipPath)) {
    Write-Error "Site package does not exist" -Category:ObjectNotFound -CategoryActivity:"Extract DNN site" -CategoryTargetName:$SiteZipPath -TargetObject:$SiteZipPath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    Break
  }

  if (Test-Path $SiteZipPath -PathType Leaf) {
    $SiteZipOutputPath = Join-Path $sitePath  "Extracted_Website"
    extractZip $SiteZipOutputPath $SiteZipPath
    $SiteZipPath = $SiteZipOutputPath
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
    $destination = $file.FullName -replace [regex]::escape($from), $to;
    Write-Progress -Activity:$activity -Status:$status -PercentComplete ($progressCount / $totalCount * 100) -CurrentOperation:$destination;
    $directory = Split-Path $destination;
    $baseDirectory = Split-Path $directory;
    $directoryName = Split-Path $directory -Leaf;
    New-Item -Path:$baseDirectory -Name:$directoryName -ItemType:Directory -Force -Confirm:$false | Out-Null;
    Invoke-Command -ScriptBlock:$process -ArgumentList:@($file.FullName, $destination);
  }

  Write-Progress -Activity:$activity -PercentComplete 100 -Completed;
}

function newDnnDatabase {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$Name
  );

  Invoke-Sqlcmd -Query:"CREATE DATABASE [$Name];" -Database:master
  Invoke-Sqlcmd -Query:"ALTER DATABASE [$Name] SET RECOVERY SIMPLE;" -Database:master
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
  $logos = Invoke-Sqlcmd -Query:"SELECT HomeDirectory + N'/' + LogoFile AS Logo FROM $(getDnnDatabaseObjectName -objectName:'Vw_Portals' -DatabaseOwner:$DatabaseOwner -ObjectQualifier:$ObjectQualifier) WHERE LogoFile IS NOT NULL" -Database:$Name
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
