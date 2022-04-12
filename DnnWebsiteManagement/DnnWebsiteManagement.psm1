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
if ($null -eq $www) { $www = 'C:\inetpub\wwwroot' }

Add-Type -TypeDefinition @"
   public enum DnnProduct
   {
      DnnPlatform,
      EvoqContent,
      EvoqContentEnterprise,
      EvoqEngage,
   }
"@

function Install-DNNResources {
  param(
    [parameter(Mandatory = $false, position = 0)]
    [string]$siteName
  );

  if ($siteName -eq '' -and $PWD.Provider.Name -eq 'FileSystem' -and $PWD.Path.StartsWith("$www\")) {
    $siteName = $PWD.Path.Split('\')[3]
    Write-Verbose "Site name is '$siteName'"
  }

  if ($siteName -eq '') {
    throw 'You must specify the site name (e.g. dnn.local) if you are not in the website'
  }

  try {
    $result = Invoke-WebRequest "https://$siteName/Install/Install.aspx?mode=InstallResources"

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
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local).  If not specified, this is derived from the current folder path
#>
}

function Remove-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName
  );

  Assert-AdministratorRole

  #TODO: remove certificate
  if ($PSCmdlet.ShouldProcess($siteName, 'Remove HTTPS Binding')) {
    Remove-SslWebBinding $siteName;
  }

  $website = Get-IISSite $siteName;
  if ($website) {
    foreach ($binding in $website.Bindings) {
      if ($binding.sslFlags -eq 1) {
        $hostHeader = $binding.bindingInformation.Substring(6) #remove "*:443:" from the beginning of the binding info
        if ($PSCmdlet.ShouldProcess($hostHeader, 'Remove HTTPS Binding')) {
          Remove-SslWebBinding $siteName $hostHeader;
        }
      }
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Remove IIS Site')) {
      Remove-IISSite $siteName;
    }
  }

  $serverManager = Get-IISServerManager
  $appPool = $serverManager.ApplicationPools[$siteName];
  if ($appPool) {
    Write-Information "Removing $siteName app pool from IIS"

    if ($PSCmdlet.ShouldProcess($siteName, 'Remove IIS App Pool')) {
      $appPool.Delete();
      $serverManager.CommitChanges();
    }
  }
  else {
    Write-Information "$siteName app pool not found in IIS"
  }

  if (Test-Path $www\$siteName) {
    if ($PSCmdlet.ShouldProcess($siteName, "Remove $www\$siteName")) {
      Remove-Item $www\$siteName -Recurse -Force -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }
  else {
    Write-Information "$www\$siteName does not exist"
  }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)") {
    if ($PSCmdlet.ShouldProcess($siteName, 'Drop Database')) {
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
      Invoke-Sqlcmd -Query:"DROP DATABASE [$siteName];" -ServerInstance:. -Database:master
    }
  }
  else {
    Write-Information "$siteName database not found"
  }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(ConvertTo-EncodedSqlName "IIS AppPool\$siteName")") {
    if ($PSCmdlet.ShouldProcess("IIS AppPool\$siteName", 'Drop login')) {
      Invoke-Sqlcmd -Query:"DROP LOGIN [IIS AppPool\$siteName];" -Database:master
    }
  }
  else {
    Write-Information "IIS AppPool\$siteName database login not found"
  }

  #TODO: remove all host entries added during restore
  if ($PSCmdlet.ShouldProcess($siteName, 'Remove HOSTS file entry')) {
    Remove-HostFileEntry $siteName -WhatIf:$WhatIfPreference -Confirm:$false;
  }

  <#
.SYNOPSIS
    Destroys a DNN site
.DESCRIPTION
    Destroys a DNN site, removing it from the file system, IIS, and the database
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
#>
}

function Rename-DNNSite {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$oldSiteName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$newSiteName
  );

  Assert-AdministratorRole

  $serverManager = Get-IISServerManager
  $appPool = $serverManager.ApplicationPools[$oldSiteName]
  if ($appPool -and $appPool.State -eq 'Started') {
    $appPool.Stop()
    while ($appPool.State -ne 'Stopped') {
      Start-Sleep -m 100
    }
  }

  if (Test-Path $www\$oldSiteName) {
    Write-Information "Renaming $www\$oldSiteName to $newSiteName"
    Rename-Item $www\$oldSiteName $newSiteName
  }
  else {
    Write-Information "$www\$oldSiteName does not exist"
  }

  $website = $serverManager.Sites[$oldSiteName];
  $app = $website.Applications['/'];
  $virtualDirectory = $app.VirtualDirectories['/'];
  $virtualDirectory.PhysicalPath = "$www\$newSiteName\Website";
  Remove-IISSiteBinding -Name:$oldSiteName -BindingInformation:"*:80:$oldSiteName"
  New-IISSiteBinding -Name:$oldSiteName -BindingInformation:"*:80:$newSiteName" -Protocol:'http'

  Write-Information "Renaming $oldSiteName site in IIS to $newSiteName"
  Write-Information "Renaming $oldSiteName app pool in IIS to $newSiteName"
  $website.Name = $newSiteName;
  $appPool.Name = $newSiteName;
  $app.ApplicationPoolName = $newSiteName;

  $serverManager.CommitChanges();

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $oldSiteName)") {
    Write-Information "Closing connections to $oldSiteName database"
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$oldSiteName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
    Write-Information "Renaming $oldSiteName database to $newSiteName"
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$oldSiteName] MODIFY NAME = [$newSiteName];" -ServerInstance:. -Database:master
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$newSiteName] SET MULTI_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
  }
  else {
    Write-Information "$oldSiteName database not found"
  }

  if (-not (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(ConvertTo-EncodedSqlName "IIS AppPool\$newSiteName")")) {
    Write-Information "Creating SQL Server login for IIS AppPool\$newSiteName"
    Invoke-Sqlcmd -Query:"CREATE LOGIN [IIS AppPool\$newSiteName] FROM WINDOWS WITH DEFAULT_DATABASE = [$newSiteName];" -Database:master
  }
  Write-Information "Creating SQL Server user"
  Invoke-Sqlcmd -Query:"CREATE USER [IIS AppPool\$newSiteName] FOR LOGIN [IIS AppPool\$newSiteName];" -Database:$newSiteName
  Write-Information "Adding SQL Server user to db_owner role"
  Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'IIS AppPool\$newSiteName';" -Database:$newSiteName

  $ownedRoles = Invoke-SqlCmd -Query:"SELECT p2.name FROM sys.database_principals p1 JOIN sys.database_principals p2 ON p1.principal_id = p2.owning_principal_id WHERE p1.name = 'IIS AppPool\$oldSiteName';" -Database:$newSiteName
  foreach ($roleRow in $ownedRoles) {
    $roleName = $roleRow.name
    Invoke-SqlCmd -Query:"ALTER AUTHORIZATION ON ROLE::[$roleName] TO [IIS AppPool\$newSiteName];" -Database:$newSiteName
  }

  Invoke-Sqlcmd -Query:"DROP USER [IIS AppPool\$oldSiteName];" -Database:$newSiteName

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(ConvertTo-EncodedSqlName "IIS AppPool\$oldSiteName")") {
    Write-Information "Dropping IIS AppPool\$oldSiteName database login"
    Invoke-Sqlcmd -Query:"DROP LOGIN [IIS AppPool\$oldSiteName];" -Database:master
  }
  else {
    Write-Information "IIS AppPool\$oldSiteName database login not found"
  }

  Set-ModifyPermission $www\$newSiteName\Website $newSiteName

  [xml]$webConfig = Get-Content $www\$newSiteName\Website\web.config
  $objectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
  $databaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')
  $connectionString = "Data Source=.`;Initial Catalog=$newSiteName`;Integrated Security=true"
  $webConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
  $webConfig.configuration.appSettings.add | Where-Object { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }
  $webConfig.Save("$www\$newSiteName\Website\web.config")

  Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$oldSiteName', '$newSiteName')" -Database:$newSiteName

  Remove-HostFileEntry $oldSiteName
  Add-HostFileEntry $newSiteName

  $appPool.Start();

  Write-Information "Launching https://$newSiteName"
  Start-Process -FilePath:https://$newSiteName

  <#
.SYNOPSIS
    Renames a DNN site
.DESCRIPTION
    Renames a DNN site in the file system, IIS, and the database
.PARAMETER oldSiteName
    The current name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER newSiteName
    The new name to which the site should be renamed
#>
}

function Restore-DNNSite {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$siteZip,
    [parameter(Mandatory = $true, position = 2)]
    [string]$databaseBackup,
    [parameter(Mandatory = $false)]
    [string]$sourceVersion = '',
    [parameter(Mandatory = $false)]
    [string]$oldDomain = '',
    [parameter(Mandatory = $false)]
    [switch]$includeSource = $defaultIncludeSource
  );

  $siteZipFile = Get-Item $siteZip
  if ($siteZipFile.Extension -eq '.bak') {
    $siteZip = $databaseBackup
    $databaseBackup = $siteZipFile.FullName
  }

  $includeSource = $includeSource -or $sourceVersion -ne ''
  New-DNNSite $siteName -siteZip:$siteZip -databaseBackup:$databaseBackup -version:$sourceVersion -includeSource:$includeSource -oldDomain:$oldDomain

  <#
.SYNOPSIS
    Restores a backup of a DNN site
.DESCRIPTION
    Restores a DNN site from a file system zip and database backup
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER siteZip
    The full path to the zip (any format that 7-Zip can expand) of the site's file system, or the full path to a folder with the site's contents
.PARAMETER databaseBackup
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER sourceVersion
    If specified, the DNN source for this version will be included with the site
.PARAMETER sourceProduct
    If specified, the DNN product to use for the source (assumes sourceVersion is also specified).  Defaults to DnnPlatform
.PARAMETER oldDomain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
#>
}

function Upgrade-DNNSite {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $false, position = 1)]
    [string]$version = $defaultDNNVersion,
    [parameter(Mandatory = $false, position = 2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $defaultIncludeSource
  );

  extractPackages -SiteName:$siteName -Version:$version -Product:$product -IncludeSource:$includeSource -UseUpgradePackage

  Write-Information "Launching https://$siteName/Install/Install.aspx?mode=upgrade"
  Start-Process -FilePath:https://$siteName/Install/Install.aspx?mode=upgrade

  <#
.SYNOPSIS
    Upgrades a DNN site
.DESCRIPTION
    Upgrades an existing DNN site to the specified version
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER version
    The version of DNN to which the site should be upgraded.  Defaults to $defaultDNNVersion
.PARAMETER product
    The DNN product for the upgrade package.  Defaults to DnnPlatform
.PARAMETER includeSource
    Whether to include the DNN source
#>
}

function New-DNNSite {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $false, position = 1)]
    [string]$version = $defaultDNNVersion,
    [parameter(Mandatory = $false, position = 2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $defaultIncludeSource,
    [string]$objectQualifier = '',
    [string]$databaseOwner = 'dbo',
    [string]$siteZip = '',
    [string]$databaseBackup = '',
    [string]$oldDomain = ''
  );

  Assert-AdministratorRole

  $siteNameExtension = [System.IO.Path]::GetExtension($siteName)
  if ($siteNameExtension -eq '') { $siteNameExtension = '.local' }

  if ($PSCmdlet.ShouldProcess($siteName, 'Extract Package')) {
    extractPackages -SiteName:$siteName -Version:$version -Product:$product -IncludeSource:$includeSource -SiteZip:$siteZip
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Add HOSTS file entry')) {
    Add-HostFileEntry $siteName
  }

  $serverManager = Get-IISServerManager;
  if ($PSCmdlet.ShouldProcess($siteName, 'Create IIS App Pool')) {
    $serverManager.ApplicationPools.Add($siteName);
    $serverManager.CommitChanges();
  }
  if ($PSCmdlet.ShouldProcess($siteName, 'Create IIS Site')) {
    $website = $serverManager.Sites.Add($siteName, 'http', "*:80:$siteName", "$www\$siteName\Website");
    $website.Applications['/'].ApplicationPoolName = $siteName;
    $serverManager.CommitChanges();
  }

  $domains = New-Object System.Collections.Generic.List[System.String]
  $domains.Add($siteName)

  Write-Information "Setting modify permission on website files for IIS AppPool\$siteName"
  Set-ModifyPermission $www\$siteName\Website $siteName -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference;

  [xml]$webConfig = Get-Content $www\$siteName\Website\web.config
  if ($databaseBackup -eq '') {
    if ($PSCmdlet.ShouldProcess($siteName, 'Create Database')) {
      newDnnDatabase $siteName
    }
    # TODO: create schema if $databaseOwner has been passed in
  }
  else {
    if ($PSCmdlet.ShouldProcess($databaseBackup, 'Restore Database')) {
      restoreDnnDatabase $siteName (Get-Item $databaseBackup).FullName
      Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET RECOVERY SIMPLE"
    }

    $objectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $databaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')

    if ($oldDomain -ne '') {
      if ($PSCmdlet.ShouldProcess($siteName, 'Update Portal Aliases')) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$oldDomain', '$siteName')" -Database:$siteName
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = REPLACE(SettingValue, '$oldDomain', '$siteName') WHERE SettingName = 'DefaultPortalAlias'" -Database:$siteName
      }

      $aliases = Invoke-Sqlcmd -Query:"SELECT HTTPAlias FROM $(getDnnDatabaseObjectName -objectName:'PortalAlias' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) WHERE HTTPAlias != '$siteName'" -Database:$siteName
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

        if ($aliasHost -NotLike "*$siteName*") {
          $aliasHost = $aliasHost + $siteNameExtension
          $newAlias = $aliasHost
          if ($port -ne 80) {
            $newAlias = $newAlias + ':' + $port
          }

          if ($childAlias) {
            $newAlias = $newAlias + '/' + $childAlias
          }

          if ($PSCmdlet.ShouldProcess($newAlias, 'Rename alias')) {
            Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalAlias' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET HTTPAlias = '$newAlias' WHERE HTTPAlias = '$alias'" -Database:$siteName
          }
        }

        $existingBinding = Get-IISSiteBinding -Name:$siteName -BindingInformation:"*:$($port):$aliasHost" -Protocol:http
        if ($null -eq $existingBinding) {
          Write-Verbose "Setting up IIS binding and HOSTS entry for $aliasHost"
          if ($PSCmdlet.ShouldProcess($aliasHost, 'Create IIS Site Binding')) {
            New-IISSiteBinding -Name:$siteName -BindingInformation:"*:$($port):$aliasHost" -Protocol:http -Confirm:$false;
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

    if ($objectQualifier -ne '') {
      $oq = $objectQualifier + '_'
    }
    else {
      $oq = ''
    }

    $catalookSettingsTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)\Tables\$databaseOwner.${oq}CAT_Settings"
    if (Test-Path $catalookSettingsTablePath -and $PSCmdlet.ShouldProcess($siteName, 'Set Catalook to test mode')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'CAT_Settings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET PostItems = 0, StorePaymentTypes = 32, StoreCCTypes = 23, CCLogin = '${env:CatalookTestCCLogin}', CCPassword = '${env:CatalookTestCCPassword}', CCMerchantHash = '${env:CatalookTestCCMerchantHash}', StoreCurrencyid = 2, CCPaymentProcessorID = 59, LicenceKey = '${env:CatalookTestLicenseKey}', StoreEmail = '${env:CatalookTestStoreEmail}', Skin = '${env:CatalookTestSkin}', EmailTemplatePackage = '${env:CatalookTestEmailTemplatePackage}', CCTestMode = 1, EnableAJAX = 1" -Database:$siteName
    }

    $esmSettingsTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)\Tables\$databaseOwner.${oq}esm_Settings"
    if (Test-Path $esmSettingsTablePath -and $PSCmdlet.ShouldProcess($siteName, 'Set FattMerchant to test mode')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Settings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET MerchantRegistrationStatusId = null, FattmerchantMerchantId = null, FattmerchantApiKey = '${env:FattmerchantTestApiKey}', FattmerchantPaymentsToken = '${env:FattmerchantTestPaymentsToken}' WHERE CCPaymentProcessorID = 185" -Database:$siteName
    }

    $esmParticipantTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)\Tables\$databaseOwner.${oq}esm_Participant"
    if (Test-Path $esmParticipantTablePath -and $PSCmdlet.ShouldProcess($siteName, 'Turn off payment processing for Engage: AMS')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'esm_Participant' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET PaymentProcessorCustomerId = NULL" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Turn off SMTP for Mandeeps Live Campaign')) {
      $liveCampaignSettingTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)\Tables\$databaseOwner.${oq}LiveCampaign_Setting"
      if (Test-Path $liveCampaignSettingTablePath) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_Setting' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SMTPServerMode = 'DNNHostSettings', SendGridAPI = NULL WHERE SMTPServerMode = 'Sendgrid'" -Database:$siteName
      }

      $liveCampaignSmtpTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(ConvertTo-EncodedSqlName $siteName)\Tables\$databaseOwner.${oq}LiveCampaign_SmtpServer"
      if (Test-Path $liveCampaignSmtpTablePath) {
        Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'LiveCampaign_SmtpServer' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET Server = 'localhost', Username = '', Password = ''" -Database:$siteName
      }
    }

    if (Test-Path $www\$siteName\Website\DesktopModules\EngageSports -and $PSCmdlet.ShouldProcess($siteName, 'Update Engage: Sports wizard URLs')) {
      updateWizardUrls $siteName
    }

    Write-Information "Setting SMTP to localhost"
    if ($PSCmdlet.ShouldProcess($siteName, 'Set SMTP to localhost')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$siteName

      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$siteName
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'PortalSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Clear WebServers table')) {
      Invoke-Sqlcmd -Query:"TRUNCATE TABLE $(getDnnDatabaseObjectName -objectName:'WebServers' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier)" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Turn off event log buffer')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'HostSettings' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'EventLogBuffer'" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Turn off search crawler')) {
      Invoke-Sqlcmd -Query:"UPDATE $(getDnnDatabaseObjectName -objectName:'Schedule' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) SET Enabled = 0 WHERE TypeFullName = 'DotNetNuke.Professional.SearchCrawler.SearchSpider.SearchSpider, DotNetNuke.Professional.SearchCrawler'" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, "Set all passwords to 'pass'")) {
      Invoke-Sqlcmd -Query:"UPDATE aspnet_Membership SET PasswordFormat = 0, Password = 'pass'" -Database:$siteName
    }

    if ($PSCmdlet.ShouldProcess($siteName, 'Watermark site logo(s)')) {
      watermarkLogos $siteName $siteNameExtension
    }

    if (Test-Path "$www\$siteName\Website\ApplicationInsights.config" -and $PSCmdlet.ShouldProcess($siteName, 'Remove Application Insights config')) {
      Remove-Item "$www\$siteName\Website\ApplicationInsights.config" -WhatIf:$WhatIfPreference -Confirm:$false;
    }
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Set connectionString in web.config')) {
    $connectionString = "Data Source=.`;Initial Catalog=$siteName`;Integrated Security=true"
    $webConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
    $webConfig.configuration.appSettings.add | Where-Object { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }
    $webConfig.Save("$www\$siteName\Website\web.config")
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Set objectQualifier and databaseOwner in web.config')) {
    $webConfig.configuration.dotnetnuke.data.providers.add | Where-Object { $_.name -eq 'SqlDataProvider' } | ForEach-Object { $_.objectQualifier = $objectQualifier; $_.databaseOwner = $databaseOwner }
    $webConfig.Save("$www\$siteName\Website\web.config")
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Update web.config to allow short passwords')) {
    $webConfig.configuration['system.web'].membership.providers.add | Where-Object { $_.type -eq 'System.Web.Security.SqlMembershipProvider' } | ForEach-Object { $_.minRequiredPasswordLength = '4' }
    $webConfig.Save("$www\$siteName\Website\web.config")
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Turn on debug mode in web.config')) {
    $webConfig.configuration['system.web'].compilation.debug = 'true'
    $webConfig.Save("$www\$siteName\Website\web.config")
  }

  if (-not (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(ConvertTo-EncodedSqlName "IIS AppPool\$siteName")") -and $PSCmdlet.ShouldProcess("IIS AppPool\$siteName", 'Create SQL Server login')) {
    Invoke-Sqlcmd -Query:"CREATE LOGIN [IIS AppPool\$siteName] FROM WINDOWS WITH DEFAULT_DATABASE = [$siteName];" -Database:master
  }

  if ($PSCmdlet.ShouldProcess("IIS AppPool\$siteName", 'Create SQL Server User')) {
    Invoke-Sqlcmd -Query:"CREATE USER [IIS AppPool\$siteName] FOR LOGIN [IIS AppPool\$siteName];" -Database:$siteName
  }
  if ($PSCmdlet.ShouldProcess("IIS AppPool\$siteName", 'Add db_owner role')) {
    Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'IIS AppPool\$siteName';" -Database:$siteName
  }

  if ($PSCmdlet.ShouldProcess($siteName, 'Add HTTPS bindings')) {
    New-SslWebBinding $siteName $domains -WhatIf:$WhatIfPreference -Confirm:$false;
  }

  if ($PSCmdlet.ShouldProcess("https://$siteName", 'Open browser')) {
    Start-Process -FilePath:https://$siteName
  }

  <#
.SYNOPSIS
    Creates a DNN site
.DESCRIPTION
    Creates a DNN site, either from a file system zip and database backup, or a new installation
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER version
    The DNN version  Defaults to $defaultDnnVersion
.PARAMETER product
    The DNN product.  Defaults to DnnPlatform
.PARAMETER includeSource
    Whether to include the DNN source files
.PARAMETER objectQualifier
    The database object qualifier
.PARAMETER databaseOwner
    The database schema
.PARAMETER databaseBackup
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER sourceVersion
    If specified, the DNN source for this version will be included with the site
.PARAMETER oldDomain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
#>
}

function getPackageName([System.Version]$version, [DnnProduct]$product) {
  $72version = New-Object System.Version("7.2")
  $74version = New-Object System.Version("7.4")
  if ($version -lt $72version) {
    $productPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DotNetNuke_Community"
      [DnnProduct]::EvoqContent           = "DotNetNuke_Professional"
      [DnnProduct]::EvoqContentEnterprise = "DotNetNuke_Enterprise"
      [DnnProduct]::EvoqEngage            = "Evoq_Social"
    }
  }
  elseif ($version -lt $74version) {
    $productPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DNN_Platform"
      [DnnProduct]::EvoqContent           = "Evoq_Content"
      [DnnProduct]::EvoqContentEnterprise = "Evoq_Enterprise"
      [DnnProduct]::EvoqEngage            = "Evoq_Social"
    }
  }
  else {
    $productPackageNames = @{
      [DnnProduct]::DnnPlatform           = "DNN_Platform"
      [DnnProduct]::EvoqContent           = "Evoq_Content_Basic"
      [DnnProduct]::EvoqContentEnterprise = "Evoq_Content"
      [DnnProduct]::EvoqEngage            = "Evoq_Engage"
    }
  }
  return $productPackageNames.Get_Item($product)
}

function findPackagePath([System.Version]$version, [DnnProduct]$product, [string]$type) {
  $majorVersion = $version.Major
  switch ($product) {
    DnnPlatform { $packagesFolder = "${env:soft}\DNN\Versions\DotNetNuke $majorVersion"; break; }
    EvoqContent { $packagesFolder = "${env:soft}\DNN\Versions\Evoq Content Basic"; break; }
    EvoqContentEnterprise { $packagesFolder = "${env:soft}\DNN\Versions\Evoq Content"; break; }
    EvoqEngage { $packagesFolder = "${env:soft}\DNN\Versions\Evoq Engage"; break; }
  }

  $packageName = getPackageName $version $product

  $formattedVersion = $version.Major.ToString('0') + '.' + $version.Minor.ToString('0') + '.' + $version.Build.ToString('0')
  $package = Get-Item "$packagesFolder\${packageName}_${formattedVersion}*_${type}.zip"
  if ($null -eq $package) {
    $formattedVersion = $version.Major.ToString('0#') + '.' + $version.Minor.ToString('0#') + '.' + $version.Build.ToString('0#')
    $package = Get-Item "$packagesFolder\${packageName}_${formattedVersion}*_${type}.zip"
  }

  if (($null -eq $package) -and ($product -ne [DnnProduct]::DnnPlatform)) {
    return findPackagePath -version:$version -product:DnnPlatform -type:$type
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
      $process = Start-Process $commandName -ArgumentList "x -y -o`"$output`" -- `"$zipFile`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outputFile
      if ($process.ExitCode -ne 0) {
        if ($process.ExitCode -eq 1) {
          Write-Warning "Non-fatal error extracting $zipFile, opening 7-Zip output"
        }
        else {
          Write-Warning "Error extracting $zipFile, opening 7-Zip output"
        }

        $zipLogOutput = Get-Content $outputFile;
        if ($zipLogOutput) {
          Write-Warning $zipLogOutput
        }
      }
    }
    finally {
      Remove-Item $outputFile
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
    [string]$siteName,
    [parameter(Mandatory = $false, position = 1)]
    [string]$version,
    [parameter(Mandatory = $true, position = 2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $defaultIncludeSource,
    [string]$siteZip = '',
    [switch]$useUpgradePackage
  );

  $siteZipOutput = $null;
  if ($siteZip -ne '') {
    if (Test-Path $siteZip -PathType Leaf) {
      $siteZipOutput = "$www\$siteName\Extracted_Website"
      extractZip "$siteZipOutput" "$siteZip"
      $siteZip = $siteZipOutput
      $unzippedFiles = @(Get-ChildItem $siteZipOutput -Directory)
      if ($unzippedFiles.Length -eq 1) {
        $siteZip += "\$unzippedFiles"
      }
    }

    $assemblyPath = "$siteZip\bin\DotNetNuke.dll"
    $version = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Version
    Write-Verbose "Found version $version of DotNetNuke.dll"
  }
  elseif ($null -eq $env:soft) {
    throw 'You must set the environment variable `soft` to the path that contains your DNN install packages'
  }

  if ($version -eq '') {
    $version = $defaultDNNVersion
  }

  $version = New-Object System.Version($version)
  Write-Verbose "Version is $version"

  if ($includeSource -eq $true) {
    Write-Information "Extracting DNN $version source"
    $sourcePath = findPackagePath -version:$version -product:$product -type:'Source'
    Write-Verbose "Source Path is $sourcePath"
    if ($null -eq $sourcePath -or $sourcePath -eq '' -or -not (Test-Path $sourcePath)) {
      Write-Error "Fallback source package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Extract DNN $version source" -CategoryTargetName:$sourcePath -TargetObject:$sourcePath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    }
    Write-Verbose "extracting from $sourcePath to $www\$siteName"
    extractZip "$www\$siteName" "$sourcePath"
    if (Test-Path "$www\$siteName\Platform\Website\" -PathType Container) {
      Copy-Item "$www\$siteName\Platform\*" "$www\$siteName\" -Force -Recurse
      Remove-Item "$www\$siteName\Platform\" -Force -Recurse
    }

    Write-Information "Copying DNN $version source symbols into install directory"
    $symbolsPath = findPackagePath -version:$version -product:$product -type:'Symbols'
    Write-Verbose "Symbols Path is $sourcePath"
    if ($null -eq $symbolsPath -or $symbolsPath -eq '' -or -not (Test-Path $symbolsPath)) {
      Write-Error "Fallback symbols package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Copy DNN $version source symbols" -CategoryTargetName:$symbolsPath -TargetObject:$symbolsPath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    }
    Write-Verbose "cp $symbolsPath $www\$siteName\Website\Install\Module"
    Copy-Item $symbolsPath $www\$siteName\Website\Install\Module

    Write-Information "Updating site URL in sln files"
    Get-ChildItem $www\$siteName\*.sln | ForEach-Object {
      $slnContent = (Get-Content $_);
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Community"', "`"https://$siteName`"";
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Professional"', "`"https://$siteName`"";
      $slnContent = $slnContent -replace '"http://localhost/DotNetNuke_Enterprise"', "`"https://$siteName`"";
      $slnContent = $slnContent -replace '"http://localhost/DNN_Platform"', "`"https://$siteName`""; # DNN 7.1.2+
      Set-Content $_ $slnContent;
    }
  }

  if ($siteZip -eq '') {
    if ($useUpgradePackage) {
      $siteZip = findPackagePath -version:$version -product:$product -type:'Upgrade'
    }
    else {
      $siteZip = findPackagePath -version:$version -product:$product -type:'Install'
    }

    if ($null -eq $siteZip -or $siteZip -eq '' -or -not (Test-Path $siteZip)) {
      throw "The package for $product $version could not be found, aborting installation"
    }
  }
  elseif ($siteZip -eq $null -or $siteZip -eq '' -or -not (Test-Path $siteZip)) {
    throw "The supplied file $siteZip could not be found, aborting installation"
  }

  $siteZip = (Get-Item $siteZip).FullName
  Write-Information "Extracting DNN site"
  if (-not (Test-Path $siteZip)) {
    Write-Error "Site package does not exist" -Category:ObjectNotFound -CategoryActivity:"Extract DNN site" -CategoryTargetName:$siteZip -TargetObject:$siteZip -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    Break
  }

  if (Test-Path $siteZip -PathType Leaf) {
    $siteZipOutput = "$www\$siteName\Extracted_Website"
    extractZip "$siteZipOutput" "$siteZip"
    $siteZip = $siteZipOutput
  }

  $to = "$www\$siteName\Website"
  $from = "$siteZip/"

  # add * only if the directory already exists, based on https://groups.google.com/d/msg/microsoft.public.windows.powershell/iTEakZQQvh0/TLvql_87yzgJ
  if (Test-Path $to -PathType Container) { $from += '*' }
  Copy-Item $from $to -Force -Recurse

  if ($siteZipOutput) {
    Remove-Item $siteZipOutput -Force -Recurse
  }
}

function newDnnDatabase {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName
  );

  Invoke-Sqlcmd -Query:"CREATE DATABASE [$siteName];" -Database:master
  Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET RECOVERY SIMPLE;" -Database:master
}

function restoreDnnDatabase {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$databaseBackup
  );

  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server') {
    $defaultInstanceKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' | Where-Object { $_.Name -match 'MSSQL\d+\.MSSQLSERVER$' } | Select-Object
    if ($defaultInstanceKey) {
      $defaultInstanceInfoPath = Join-Path $defaultInstanceKey.PSPath 'MSSQLServer'
      $backupDir = $(Get-ItemProperty -path:$defaultInstanceInfoPath -name:BackupDirectory).BackupDirectory
      if ($backupDir) {
        $sqlAcl = Get-Acl $backupDir
        Set-Acl $databaseBackup $sqlAcl
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

  #based on http://redmondmag.com/articles/2009/12/21/automated-restores.aspx
  $server = New-Object Microsoft.SqlServer.Management.Smo.Server('(local)')
  $dbRestore = New-Object Microsoft.SqlServer.Management.Smo.Restore

  $dbRestore.Action = 'Database'
  $dbRestore.NoRecovery = $false
  $dbRestore.ReplaceDatabase = $true
  $dbRestore.Devices.AddDevice($databaseBackup, [Microsoft.SqlServer.Management.Smo.DeviceType]::File)
  $dbRestore.Database = $siteName

  $dbRestoreFile = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile
  $dbRestoreLog = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile

  $logicalDataFileName = $siteName
  $logicalLogFileName = $siteName

  foreach ($file in $dbRestore.ReadFileList($server)) {
    switch ($file.Type) {
      'D' { $logicalDataFileName = $file.LogicalName }
      'L' { $logicalLogFileName = $file.LogicalName }
    }
  }

  $dbRestoreFile.LogicalFileName = $logicalDataFileName
  $dbRestoreFile.PhysicalFileName = $server.Information.MasterDBPath + '\' + $siteName + '_Data.mdf'
  $dbRestoreLog.LogicalFileName = $logicalLogFileName
  $dbRestoreLog.PhysicalFileName = $server.Information.MasterDBLogPath + '\' + $siteName + '_Log.ldf'

  $dbRestore.RelocateFiles.Add($dbRestoreFile) | Out-Null
  $dbRestore.RelocateFiles.Add($dbRestoreLog) | Out-Null

  try {
    $dbRestore.SqlRestore($server)
  }
  catch [System.Exception] {
    Write-Output $_.Exception
  }
}

function getDnnDatabaseObjectName {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$objectName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$databaseOwner,
    [parameter(Mandatory = $false, position = 2)]
    [string]$objectQualifier
  );

  if ($objectQualifier -ne '') { $objectQualifier += '_' }
  return $databaseOwner + ".[$objectQualifier$objectName]"
}

function updateWizardUrls {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName
  );

  $uri = $null
  foreach ($wizardManifest in (Get-ChildItem $www\$siteName\Website\DesktopModules\EngageSports\*Wizard*.xml)) {
    [xml]$wizardXml = Get-Content $wizardManifest
    foreach ($urlNode in $wizardXml.GetElementsByTagName("NextUrl")) {
      if ([System.Uri]::TryCreate([string]$urlNode.InnerText, [System.UriKind]::Absolute, [ref] $uri)) {
        $urlNode.InnerText = "https://$siteName" + $uri.AbsolutePath
      }
    }

    $wizardXml.Save($wizardManifest.FullName)
  }
}

function watermarkLogos {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $true, position = 1)]
    [string]$siteNameExtension
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

  $logos = Invoke-Sqlcmd -Query:"SELECT HomeDirectory + N'/' + LogoFile AS Logo FROM $(getDnnDatabaseObjectName -objectName:'Vw_Portals' -databaseOwner:$databaseOwner -objectQualifier:$objectQualifier) WHERE LogoFile IS NOT NULL" -Database:$siteName
  $watermarkText = $siteNameExtension.Substring(1)
  foreach ($logo in $logos) {
    $logoFile = "$www\$siteName\Website\" + $logo.Logo.Replace('/', '\')
    & $cmd $subCmd -font Arial -pointsize 60 -draw "gravity Center fill #00ff00 text 0,0 $watermarkText" -draw "gravity NorthEast fill #ff00ff text 0,0 $watermarkText" -draw "gravity SouthWest fill #00ffff text 0,0 $watermarkText" -draw "gravity NorthWest fill #ff0000 text 0,0 $watermarkText" -draw "gravity SouthEast fill #0000ff text 0,0 $watermarkText" $logoFile
  }
}

Export-ModuleMember Install-DNNResources
Export-ModuleMember Remove-DNNSite
Export-ModuleMember Rename-DNNSite
Export-ModuleMember New-DNNSite
Export-ModuleMember Upgrade-DNNSite
Export-ModuleMember Restore-DNNSite
