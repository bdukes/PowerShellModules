#Requires -Version 3
#Requires -Modules WebAdministration, Add-HostFileEntry, AdministratorRole, PKI, SslWebBinding, PSCX
Set-StrictMode -Version:Latest

Import-Module WebAdministration

Push-Location
Import-Module SQLPS -DisableNameChecking
Pop-Location

$defaultDNNVersion = '8.0.4'

$www = $env:www
if ($www -eq $null) { $www = 'C:\inetpub\wwwroot' }

Add-Type -TypeDefinition @"
   public enum DnnProduct
   {
      DnnPlatform,
      EvoqContent,
      EvoqContentEnterprise,
      ////EvoqSocial, // TODO: support Social/Engage
   }
"@

function Install-DNNResources {
    param(
        [parameter(Mandatory=$false,position=0)]
        [string]$siteName
    );

    if ($siteName -eq '' -and $PWD.Provider.Name -eq 'FileSystem' -and $PWD.Path.StartsWith("$www\")) {
        $siteName = $PWD.Path.Split('\')[3]
        Write-Verbose "Site name is '$siteName'"
    }

    if ($siteName -eq '') {
        throw 'You must specify the site name (e.g. dnn.local) if you are not in the website'
    }

    try
    {
        $result = Invoke-WebRequest "https://$siteName/Install/Install.aspx?mode=InstallResources"

        if ($result.StatusCode -ne 200) {

            Write-Warning "There was an error trying to install the resources: Status code $($result.StatusCode)"
            return
        }

        Write-HtmlNode $result.ParsedHtml.documentElement -excludeAttributes -excludeEmptyElements -excludeComments
    }
    catch
    {
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
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName
  );

  Assert-AdministratorRole

  #TODO: remove certificate
  Remove-SslWebBinding $siteName

  if (Test-Path IIS:\Sites\$siteName) {
    $website = Get-Website $siteName
    foreach ($binding in $website.Bindings.Collection) {
        if ($binding.sslFlags -eq 1) {
            $hostHeader = $binding.bindingInformation.Substring(6) #remove "*:443:" from the beginning of the binding info
            Remove-SslWebBinding $siteName $hostHeader
        }
    }

    Write-Host "Removing $siteName website from IIS"
    Remove-Website $siteName
  } else {
    Write-Host "$siteName website not found in IIS"
  }

  if (Test-Path IIS:\AppPools\$siteName) {
    Write-Host "Removing $siteName app pool from IIS"
    Remove-WebAppPool $siteName
  } else {
    Write-Host "$siteName app pool not found in IIS"
  }

  if (Test-Path $www\$siteName) {
    Write-Host "Deleting $www\$siteName"
    Remove-Item $www\$siteName -Recurse -Force
  } else {
    Write-Host "$www\$siteName does not exist"
  }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(Encode-SQLName $siteName)") {
    Write-Host "Closing connections to $siteName database"
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
    Write-Host "Dropping $siteName database"
    Invoke-Sqlcmd -Query:"DROP DATABASE [$siteName];" -ServerInstance:. -Database:master
  } else {
    Write-Host "$siteName database not found"
  }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$siteName")") {
    Write-Host "Dropping IIS AppPool\$siteName database login"
    Invoke-Sqlcmd -Query:"DROP LOGIN [IIS AppPool\$siteName];" -Database:master
  } else {
    Write-Host "IIS AppPool\$siteName database login not found"
  }

  #TODO: remove all host entries added during restore
  Remove-HostFileEntry $siteName

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
    [parameter(Mandatory=$true,position=0)]
    [string]$oldSiteName,
    [parameter(Mandatory=$true,position=1)]
    [string]$newSiteName
  );

  Assert-AdministratorRole

  if ((Test-Path IIS:\AppPools\$oldSiteName) -and (Get-WebAppPoolState $oldSiteName).Value -eq 'Started') {
    $appPool = Stop-WebAppPool $oldSiteName -Passthru
    while ($appPool.State -ne 'Stopped') {
        Start-Sleep -m 100
    }
  }

  if (Test-Path $www\$oldSiteName) {
    Write-Host "Renaming $www\$oldSiteName to $newSiteName"
    Rename-Item $www\$oldSiteName $newSiteName
  } else {
    Write-Host "$www\$oldSiteName does not exist"
  }

  Set-ItemProperty IIS:\Sites\$oldSiteName -Name PhysicalPath -Value $www\$newSiteName\Website
  Remove-WebBinding -Name:$oldSiteName -HostHeader:$oldSiteName
  New-WebBinding -Name:$oldSiteName -IP:'*' -Port:80 -Protocol:'http' -HostHeader:$newSiteName

  if (Test-Path IIS:\Sites\$oldSiteName) {
    Write-Host "Renaming $oldSiteName website in IIS to $newSiteName"
    Rename-Item IIS:\Sites\$oldSiteName $newSiteName
  } else {
    Write-Host "$oldSiteName website not found in IIS"
  }

  if (Test-Path IIS:\AppPools\$oldSiteName) {
    Write-Host "Renaming $oldSiteName app pool in IIS to $newSiteName"
    Rename-Item IIS:\AppPools\$oldSiteName $newSiteName
  } else {
    Write-Host "$oldSiteName app pool not found in IIS"
  }

  Set-ItemProperty IIS:\Sites\$newSiteName -Name ApplicationPool -Value $newSiteName

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(Encode-SQLName $oldSiteName)") {
    Write-Host "Closing connections to $oldSiteName database"
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$oldSiteName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
    Write-Host "Renaming $oldSiteName database to $newSiteName"
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$oldSiteName] MODIFY NAME = [$newSiteName];" -ServerInstance:. -Database:master
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$newSiteName] SET MULTI_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance:. -Database:master
  } else {
    Write-Host "$oldSiteName database not found"
  }

  if (-not (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$newSiteName")")) {
    Write-Host "Creating SQL Server login for IIS AppPool\$newSiteName"
    Invoke-Sqlcmd -Query:"CREATE LOGIN [IIS AppPool\$newSiteName] FROM WINDOWS WITH DEFAULT_DATABASE = [$newSiteName];" -Database:master
  }
  Write-Host "Creating SQL Server user"
  Invoke-Sqlcmd -Query:"CREATE USER [IIS AppPool\$newSiteName] FOR LOGIN [IIS AppPool\$newSiteName];" -Database:$newSiteName
  Write-Host "Adding SQL Server user to db_owner role"
  Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'IIS AppPool\$newSiteName';" -Database:$newSiteName

  $ownedRoles = Invoke-SqlCmd -Query:"SELECT p2.name FROM sys.database_principals p1 JOIN sys.database_principals p2 ON p1.principal_id = p2.owning_principal_id WHERE p1.name = 'IIS AppPool\$oldSiteName';" -Database:$newSiteName
  foreach ($roleRow in $ownedRoles) {
    $roleName = $roleRow.name
    Invoke-SqlCmd -Query:"ALTER AUTHORIZATION ON ROLE::[$roleName] TO [IIS AppPool\$newSiteName];" -Database:$newSiteName
  }

  Invoke-Sqlcmd -Query:"DROP USER [IIS AppPool\$oldSiteName];" -Database:$newSiteName

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$oldSiteName")") {
    Write-Host "Dropping IIS AppPool\$oldSiteName database login"
    Invoke-Sqlcmd -Query:"DROP LOGIN [IIS AppPool\$oldSiteName];" -Database:master
  } else {
    Write-Host "IIS AppPool\$oldSiteName database login not found"
  }

  Set-ModifyPermission $www\$newSiteName\Website $newSiteName

  [xml]$webConfig = Get-Content $www\$newSiteName\Website\web.config
  $objectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
  $databaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')
  $connectionString = "Data Source=.`;Initial Catalog=$newSiteName`;Integrated Security=true"
  $webConfig.configuration.connectionStrings.add | ? { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
  $webConfig.configuration.appSettings.add | ? { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }
  $webConfig.Save("$www\$newSiteName\Website\web.config")

  Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'PortalAlias' $databaseOwner $objectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$oldSiteName', '$newSiteName')" -Database:$newSiteName

  Remove-HostFileEntry $oldSiteName
  Add-HostFileEntry $newSiteName

  Start-WebAppPool $newSiteName

  Write-Host "Launching https://$newSiteName"
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
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$true,position=1)]
    [string]$siteZip,
    [parameter(Mandatory=$true,position=2)]
    [string]$databaseBackup,
    [parameter(Mandatory=$false)]
    [string]$sourceVersion = '',
    [parameter(Mandatory=$false)]
    [DnnProduct]$sourceProduct = [DnnProduct]::DnnPlatform,
    [parameter(Mandatory=$false)]
    [string]$oldDomain = '',
    [parameter(Mandatory=$false)]
    [switch]$includeSource = $false
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
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string]$version = $defaultDNNVersion,
    [parameter(Mandatory=$false,position=2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $true
  );

  Extract-Packages -SiteName:$siteName -Version:$version -Product:$product -IncludeSource:$includeSource -UseUpgradePackage

  Write-Host "Launching https://$siteName/Install/Install.aspx?mode=upgrade"
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
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string]$version = $defaultDNNVersion,
    [parameter(Mandatory=$false,position=2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $true,
    [string]$objectQualifier = '',
    [string]$databaseOwner = 'dbo',
    [string]$siteZip = '',
    [string]$databaseBackup = '',
    [string]$oldDomain = ''
  );

  Assert-AdministratorRole

  $siteNameExtension = [System.IO.Path]::GetExtension($siteName)
  if ($siteNameExtension -eq '') { $siteNameExtension = '.local' }
  Extract-Packages -SiteName:$siteName -Version:$version -Product:$product -IncludeSource:$includeSource -SiteZip:$siteZip

  Write-Host "Creating HOSTS file entry for $siteName"
  Add-HostFileEntry $siteName

  Write-Host "Creating IIS app pool"
  New-WebAppPool $siteName
  Write-Host "Creating IIS site"
  New-Website $siteName -HostHeader:$siteName -PhysicalPath:$www\$siteName\Website -ApplicationPool:$siteName

  New-SslWebBinding $siteName

  Write-Host "Setting modify permission on website files for IIS AppPool\$siteName"
  Set-ModifyPermission $www\$siteName\Website $siteName

  [xml]$webConfig = Get-Content $www\$siteName\Website\web.config
  if ($databaseBackup -eq '') {
    Write-Host "Creating new database"
    New-DNNDatabase $siteName
    # TODO: create schema if $databaseOwner has been passed in
  }
  else {
    Write-Host "Restoring database"
    Restore-DNNDatabase $siteName (Get-Item $databaseBackup).FullName
    Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET RECOVERY SIMPLE"

    $objectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $databaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')

    if ($oldDomain -ne '') {
        Write-Host "Updating portal aliases"
        Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'PortalAlias' $databaseOwner $objectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$oldDomain', '$siteName')" -Database:$siteName
        Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'PortalSettings' $databaseOwner $objectQualifier) SET SettingValue = REPLACE(SettingValue, '$oldDomain', '$siteName') WHERE SettingName = 'DefaultPortalAlias'" -Database:$siteName

        $aliases = Invoke-Sqlcmd -Query:"SELECT HTTPAlias FROM $(Get-DNNDatabaseObjectName 'PortalAlias' $databaseOwner $objectQualifier) WHERE HTTPAlias != '$siteName'" -Database:$siteName
        foreach ($aliasRow in $aliases) {
            $alias = $aliasRow.HTTPAlias
            Write-Verbose "Updating $alias"
            if ($alias -Like '*/*') {
                $split = $alias.Split('/')
                $aliasHost = $split[0]
                $childAlias = $split[1..($split.length - 1)] -join '/'
            } else {
                $aliasHost = $alias
                $childAlias = $null
            }

            if ($aliasHost -Like '*:*') {
                $split = $aliasHost.Split(':')
                $aliasHost = $split[0]
                $port = $split[1]
            } else {
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
                Write-Verbose "Changing $alias to $newAlias"
                Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'PortalAlias' $databaseOwner $objectQualifier) SET HTTPAlias = '$newAlias' WHERE HTTPAlias = '$alias'" -Database:$siteName
            }

            $existingBinding = Get-WebBinding -Name:$siteName -HostHeader:$aliasHost -Port:$port
            if ($existingBinding -eq $null) {
                Write-Verbose "Setting up IIS binding and HOSTS entry for $aliasHost"
                New-WebBinding -Name:$siteName -IP:'*' -Port:$port -Protocol:http -HostHeader:$aliasHost
                Add-HostFileEntry $aliasHost
            } else {
                Write-Verbose "IIS binding already exists for $aliasHost"
            }

            $existingSslBinding = Get-WebBinding -Name:$siteName -HostHeader:$aliasHost -Port:443
            if ($existingSslBinding -eq $null) {
                New-SslWebBinding -siteName:$siteName -HostHeader:$aliasHost
            }
        }
    }

    if ($objectQualifier -ne '') {
        $oq = $objectQualifier + '_'
    } else {
        $oq = ''
    }
    $catalookSettingsTablePath = "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(Encode-SQLName $siteName)\Tables\$databaseOwner.${oq}CAT_Settings"
    if (Test-Path $catalookSettingsTablePath) {
        Write-Host "Setting Catalook to test mode"
        Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'CAT_Settings' $databaseOwner $objectQualifier) SET PostItems = 0, StorePaymentTypes = 32, StoreCCTypes = 23, CCLogin = '${env:CatalookTestCCLogin}', CCPassword = '${env:CatalookTestCCPassword}', CCMerchantHash = '${env:CatalookTestCCMerchantHash}', StoreCurrencyid = 2, CCPaymentProcessorID = 59, LicenceKey = '${env:CatalookTestLicenseKey}', StoreEmail = '${env:CatalookTestStoreEmail}', Skin = '${env:CatalookTestSkin}', EmailTemplatePackage = '${env:CatalookTestEmailTemplatePackage}', CCTestMode = 1, EnableAJAX = 1" -Database:$siteName
    }

    if (Test-Path $www\$siteName\Website\DesktopModules\EngageSports) {
        Write-Host 'Updating Engage: Sports wizard URLs'
        Update-WizardUrls $siteName
    }

    Write-Host "Setting SMTP to localhost"
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database:$siteName
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database:$siteName
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database:$siteName
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database:$siteName
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database:$siteName

    Write-Host 'Clearing WebServers table'
    Invoke-Sqlcmd -Query:"TRUNCATE TABLE $(Get-DNNDatabaseObjectName 'WebServers' $databaseOwner $objectQualifier)" -Database:$siteName

    Write-Host "Turning off event log buffer"
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'EventLogBuffer'" -Database:$siteName

    Write-Host "Turning off search crawler"
    Invoke-Sqlcmd -Query:"UPDATE $(Get-DNNDatabaseObjectName 'Schedule' $databaseOwner $objectQualifier) SET Enabled = 0 WHERE TypeFullName = 'DotNetNuke.Professional.SearchCrawler.SearchSpider.SearchSpider, DotNetNuke.Professional.SearchCrawler'" -Database:$siteName

    Write-Host "Setting all passwords to 'pass'"
    Invoke-Sqlcmd -Query:"UPDATE aspnet_Membership SET PasswordFormat = 0, Password = 'pass'" -Database:$siteName

    Write-Host "Watermarking site logo(s)"
    Watermark-Logos $siteName $siteNameExtension
  }

  $connectionString = "Data Source=.`;Initial Catalog=$siteName`;Integrated Security=true"
  $webConfig.configuration.connectionStrings.add | ? { $_.name -eq 'SiteSqlServer' } | ForEach-Object { $_.connectionString = $connectionString }
  $webConfig.configuration.appSettings.add | ? { $_.key -eq 'SiteSqlServer' } | ForEach-Object { $_.value = $connectionString }

  Write-Host "Updating web.config with connection string and data provider attributes"
  $webConfig.configuration.dotnetnuke.data.providers.add | ? { $_.name -eq 'SqlDataProvider' } | ForEach-Object { $_.objectQualifier = $objectQualifier; $_.databaseOwner = $databaseOwner }
  Write-Host "Updating web.config to allow short passwords"
  $webConfig.configuration['system.web'].membership.providers.add | ? { $_.type -eq 'System.Web.Security.SqlMembershipProvider' } | ForEach-Object { $_.minRequiredPasswordLength = '4' }
  Write-Host "Updating web.config to turn on debug mode"
  $webConfig.configuration['system.web'].compilation.debug = 'true'
  $webConfig.Save("$www\$siteName\Website\web.config")

  if (-not (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$siteName")")) {
    Write-Host "Creating SQL Server login for IIS AppPool\$siteName"
    Invoke-Sqlcmd -Query:"CREATE LOGIN [IIS AppPool\$siteName] FROM WINDOWS WITH DEFAULT_DATABASE = [$siteName];" -Database:master
  }
  Write-Host "Creating SQL Server user"
  Invoke-Sqlcmd -Query:"CREATE USER [IIS AppPool\$siteName] FOR LOGIN [IIS AppPool\$siteName];" -Database:$siteName
  Write-Host "Adding SQL Server user to db_owner role"
  Invoke-Sqlcmd -Query:"EXEC sp_addrolemember N'db_owner', N'IIS AppPool\$siteName';" -Database:$siteName

  Write-Host "Launching https://$siteName"
  Start-Process -FilePath:https://$siteName

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
            [DnnProduct]::DnnPlatform = "DotNetNuke_Community"
            [DnnProduct]::EvoqContent = "DotNetNuke_Professional"
            [DnnProduct]::EvoqContentEnterprise = "DotNetNuke_Enterprise"
        }
    } elseif ($version -lt $74version) {
        $productPackageNames = @{
            [DnnProduct]::DnnPlatform = "DNN_Platform"
            [DnnProduct]::EvoqContent = "Evoq_Content"
            [DnnProduct]::EvoqContentEnterprise = "Evoq_Enterprise"
        }
    } else {
        $productPackageNames = @{
            [DnnProduct]::DnnPlatform = "DNN_Platform"
            [DnnProduct]::EvoqContent = "Evoq_Content_Basic"
            [DnnProduct]::EvoqContentEnterprise = "Evoq_Content"
        }
    }
    return $productPackageNames.Get_Item($product)
}

function Extract-Zip {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$output,
    [parameter(Mandatory=$true,position=1)]
    [string]$zipFile
  );

  Write-Verbose "extracting from $zipFile to $output"
  if (Get-Command '7zG' -ErrorAction SilentlyContinue) {
    $commandName = '7zG'
  } elseif (Get-Command '7za' -ErrorAction SilentlyContinue) {
    $commandName = '7za'
  } else {
    $commandName = $false
  }
  if ($commandName) {
      try {
        $outputFile = [System.IO.Path]::GetTempFileName()
        $process =  Start-Process $commandName -ArgumentList "x -y -o`"$output`" -- `"$zipFile`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outputFile
        if ($process.ExitCode -ne 0) {
          if ($process.ExitCode -eq 1) {
            Write-Warning "Non-fatal error extracting $zipFile, opening 7-Zip output"
          } else {
            Write-Warning "Error extracting $zipFile, opening 7-Zip output"
          }

          Edit-File $outputFile
          Start-Sleep -s 1 #sleep for one second to make sure notepad has enough time to open the file before it's deleted
        }
      }
      finally {
        Remove-Item $outputFile
      }
  } else {
      Write-Verbose 'Couldn''t find 7-Zip (try running ''choco install 7zip.commandline''), expanding with PSCX''s (slower) Expand-Archive cmdlet'
      if (-not (Test-Path $output)) {
        mkdir $output | Out-Null
      }
      Expand-Archive $zipFile -Output $output -ShowProgress
  }
}

function Extract-Packages {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string]$version,
    [parameter(Mandatory=$true,position=2)]
    [DnnProduct]$product = [DnnProduct]::DnnPlatform,
    [switch]$includeSource = $true,
    [string]$siteZip = '',
    [switch]$useUpgradePackage
  );

  if ($version -eq '') {
    Write-Verbose 'No version supplied'
    if ($siteZip -ne '') {
        if ((Get-Item $siteZip).PSIsContainer) {
            $assemblyPath = "$siteZip\bin\DotNetNuke.dll"
        } else {
            Read-Archive $siteZip | Where-Object Path -match '\bbin\\DotNetNuke\.dll$' | Expand-Archive -OutputPath $env:TEMP -FlattenPaths -Force
            $assemblyPath = "$env:TEMP\DotNetNuke.dll"
        }

        $version = (Get-FileVersionInfo $assemblyPath).ProductVersion
        Write-Verbose "Found version $version of DotNetNuke.dll"
    }
  }

  if ($version -eq '') {
    $version = $defaultDNNVersion
  }

  $v = New-Object System.Version($version)
  $majorVersion = $v.Major
  if ($majorVersion -gt 7) {
    $formattedVersion = $v.Major.ToString('0') + '.' + $v.Minor.ToString('0') + '.' + $v.Build.ToString('0')
    if ($formattedVersion -eq '8.0.4') { $formattedVersion = '8.0.4.226' }
  } else {
    $formattedVersion = $v.Major.ToString('0#') + '.' + $v.Minor.ToString('0#') + '.' + $v.Build.ToString('0#')
    if ($formattedVersion -eq '06.01.04') { $formattedVersion = '06.01.04.127' }
    if ($product -eq [DnnProduct]::EvoqContentEnterprise) {
      if ($formattedVersion -eq '07.03.01') { $formattedVersion = '7.3.1.20' }
      if ($formattedVersion -eq '07.03.02') { $formattedVersion = '7.3.2' }
    }
  }
  Write-Verbose "Formatted Version is $formattedVersion"

  if ($env:soft -eq $null) {
      throw 'You must set the environment variable `soft` to the path that contains your DNN install packages'
  }
  $packageName = getPackageName $v $product
  Write-Verbose "Package Name is $packageName"
  switch ($product) {
    DnnPlatform { $packagesFolder = "${env:soft}\DNN\Versions\DotNetNuke $majorVersion"; break; }
    EvoqContent { $packagesFolder = "${env:soft}\DNN\Versions\DotNetNuke PE"; break; }
    EvoqContentEnterprise { $packagesFolder = "${env:soft}\DNN\Versions\DotNetNuke EE"; break; }
  }
  Write-Verbose "Packages Folder is $packagesFolder"

  if ($includeSource -eq $true) {
    Write-Host "Extracting DNN $formattedVersion source"
    $sourcePath = "$packagesFolder\${packageName}_${formattedVersion}_Source.zip"
    Write-Verbose "Source Path is $sourcePath"
    if (-not (Test-Path $sourcePath)) {
        Write-Warning "Source package does not exist, falling back to community source package"
        $fallbackPackageName = getPackageName $v DnnPlatform
        $sourcePath = "${env:soft}\DNN\Versions\DotNetNuke $majorVersion\${fallbackPackageName}_${formattedVersion}_Source.zip"
        Write-Verbose "Fallback Source Path is $sourcePath"
        if (-not (Test-Path $sourcePath)) { Write-Error "Fallback source package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Extract DNN $formattedVersion community source" -CategoryTargetName:$sourcePath -TargetObject:$sourcePath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist" }
    }
    Write-Verbose "extracting from $sourcePath to $www\$siteName"
    Extract-Zip "$www\$siteName" "$sourcePath"

    Write-Host "Copying DNN $formattedVersion source symbols into install directory"
    $symbolsPath = "$packagesFolder\${packageName}_${formattedVersion}_Symbols.zip"
    Write-Verbose "Symbols Path is $sourcePath"
    if (-not (Test-Path $symbolsPath)) {
        Write-Warning "Symbols package does not exist, falling back to community symbols package"
        $fallbackPackageName = getPackageName $v DnnPlatform
        $symbolsPath = "${env:soft}\DNN\Versions\DotNetNuke $majorVersion\${fallbackPackageName}_${formattedVersion}_Symbols.zip"
        Write-Verbose "Fallback Symbols Path is $sourcePath"
        if (-not (Test-Path $symbolsPath)) { Write-Error "Fallback symbols package does not exist, either" -Category:ObjectNotFound -CategoryActivity:"Copy DNN $formattedVersion community source symbols" -CategoryTargetName:$symbolsPath -TargetObject:$symbolsPath -CategoryTargetType:".zip file" -CategoryReason:"File does not exist" }
    }
    Write-Verbose "cp $symbolsPath $www\$siteName\Website\Install\Module"
    Copy-Item $symbolsPath $www\$siteName\Website\Install\Module

    Write-Host "Updating site URL in sln files"
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
        $siteZip = "$packagesFolder\${packageName}_${formattedVersion}_Upgrade.zip"
    } else {
        $siteZip = "$packagesFolder\${packageName}_${formattedVersion}_Install.zip"
    }
  }

  $siteZip = (Get-Item $siteZip).FullName
  Write-Host "Extracting DNN site"
  if (-not (Test-Path $siteZip)) {
    Write-Error "Site package does not exist" -Category:ObjectNotFound -CategoryActivity:"Extract DNN site" -CategoryTargetName:$siteZip -TargetObject:$siteZip -CategoryTargetType:".zip file" -CategoryReason:"File does not exist"
    Break
  }

  if ((Get-Item $siteZip).PSIsContainer) {
    $from = $siteZip
    $siteZipOutput = $null
  } else {
    $siteZipOutput = "$www\$siteName\Extracted_Website"
    Extract-Zip "$siteZipOutput" "$siteZip"

    $from = $siteZipOutput
    $unzippedFiles = @(Get-ChildItem $siteZipOutput)
    if ($unzippedFiles.Length -eq 1) {
      $from += "\$unzippedFiles"
    }
  }

  # add * only if the directory already exists, based on https://groups.google.com/d/msg/microsoft.public.windows.powershell/iTEakZQQvh0/TLvql_87yzgJ
  $to = "$www\$siteName\Website"
  $from += '/'
  if (Test-Path $to -PathType Container) { $from += '*' }
  Copy-Item $from $to -Force -Recurse

  if ($siteZipOutput) {
    Remove-Item $siteZipOutput -Force -Recurse
  }
}

function New-DNNDatabase {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName
  );

  Invoke-Sqlcmd -Query:"CREATE DATABASE [$siteName];" -Database:master
  Invoke-Sqlcmd -Query:"ALTER DATABASE [$siteName] SET RECOVERY SIMPLE;" -Database:master
}

function Restore-DNNDatabase {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$true,position=1)]
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
      } else {
        Write-Warning 'Unable to find SQL Server backup directory, backup file will not have ACL permissions set'
      }
    } else {
      Write-Warning 'Unable to find SQL Server info in registry, backup file will not have ACL permissions set'
    }
  } else {
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
    write-host $_.Exception
  }
}

function Get-DNNDatabaseObjectName {
    param(
        [parameter(Mandatory=$true,position=0)]
        [string]$objectName,
        [parameter(Mandatory=$true,position=1)]
        [string]$databaseOwner,
        [parameter(Mandatory=$false,position=2)]
        [string]$objectQualifier
    );

    if ($objectQualifier -ne '') { $objectQualifier += '_' }
    return $databaseOwner + ".[$objectQualifier$objectName]"
}

function Update-WizardUrls {
    param(
        [parameter(Mandatory=$true,position=0)]
        [string]$siteName
    );

    $uri = $null
    foreach ($wizardManifest in (ls $www\$siteName\Website\DesktopModules\EngageSports\*Wizard*.xml)) {
        [xml]$wizardXml = Get-Content $wizardManifest
        foreach($urlNode in $wizardXml.GetElementsByTagName("NextUrl")) {
            if ([System.Uri]::TryCreate([string]$urlNode.InnerText, [System.UriKind]::Absolute, [ref] $uri)) {
                $urlNode.InnerText = "https://$siteName" + $uri.AbsolutePath
            }
        }

        $wizardXml.Save($wizardManifest.FullName)
    }
}

function Watermark-Logos {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$true,position=1)]
    [string]$siteNameExtension
  );

  if (Get-Command "mogrify" -ErrorAction:SilentlyContinue) {
    $logos = Invoke-Sqlcmd -Query:"SELECT HomeDirectory + N'/' + LogoFile AS Logo FROM $(Get-DNNDatabaseObjectName 'Vw_Portals' $databaseOwner $objectQualifier) WHERE LogoFile IS NOT NULL" -Database:$siteName
    $watermarkText = $siteNameExtension.Substring(1)
    foreach ($logo in $logos) {
        $logoFile = "$www\$siteName\Website\" + $logo.Logo.Replace('/', '\')
        mogrify -font Arial -pointsize 60 -draw "gravity Center fill #00ff00 text 0,0 $watermarkText" -draw "gravity NorthEast fill #ff00ff text 0,0 $watermarkText" -draw "gravity SouthWest fill #00ffff text 0,0 $watermarkText" -draw "gravity NorthWest fill #ff0000 text 0,0 $watermarkText" -draw "gravity SouthEast fill #0000ff text 0,0 $watermarkText" $logoFile
    }
  } else {
    Write-Warning "Could not watermark logos, because ImageMagick's mogrify command could not be found"
  }
}

Export-ModuleMember Install-DNNResources
Export-ModuleMember Remove-DNNSite
Export-ModuleMember Rename-DNNSite
Export-ModuleMember New-DNNSite
Export-ModuleMember Upgrade-DNNSite
Export-ModuleMember Restore-DNNSite
