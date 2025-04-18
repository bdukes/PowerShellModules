# Change Log

- March 2025
  - DnnWebsiteManagement 2.0.12
    - Revert release of 2.0.11
  - DnnWebsiteManagement 2.0.11
    - Fix error when checking for FattMerchant and Stax columns
  - DnnWebsiteManagement 2.0.10
    - Fix error during Update Portal Alias step
- February 2025
  - DnnWebsiteManagement 2.0.9
    - Fix inclusion of broken database connection logic
  - DnnWebsiteManagement 2.0.8
    - Fix incorrect original portal alias when renaming aliases
- January 2025
  - DnnWebsiteManagement 2.0.7
    - Fix error connecting to SQL Server
  - DnnWebsiteManagement 2.0.6
    - Fix error when path has trailing slash, thanks ([#30](https://github.com/bdukes/PowerShellModules/pull/30), thanks [@DanielBolef](https://github.com/DanielBolef)!)
- October 2024
  - DnnWebsiteManagement 2.0.5
    - Ensure DNN site's application pool is using .NET Framework
- September 2024
  - Recycle module was delisted because of major design flaws (see [related issue](https://github.com/bdukes/PowerShellModules/issues/29))
- October 2023
  - DnnWebsiteManagement 2.0.4
    - Fix error when extracting a site with a nested folder in the zip, the site gets deleted after extracting
- August 2023
  - DnnWebsiteManagement 2.0.3
    - Fix error when site has no custom aliases to rename
    - Fix error when web.config has a `<location>` element around `<system.web>`
    - Fix prompt about renaming aliases when there are no aliases to rename
- July 2023
  - DnnWebsiteManagement 2.0.2
    - Fix path issues when copying site from directory instead of zip
  - DnnWebsiteManagement 2.0.1
    - Fix extraneous output from `Remove-DNNSite`
    - Allow passing path to `Remove-DNNSite`
    - Remove unnecessary file copy for typical `New-DNNSite` and `Restore-DNNSite` usage
- June 2023
  - SslWebBinding 1.4.0
    - Remove certificate when removing IIS binding.
  - DnnWebsiteManagement 2.0.0
    - Remove ability to automagically look up a DNN install package on disk. Removes `-Version`, `-IncludeSource` and `-Product` parameters.
    - Remove host headers and certificates when removing a site.
  - DnnWebsiteManagement 1.8.0
    - Allow interactively choosing new portal aliases during restore ([#24](https://github.com/bdukes/PowerShellModules/pull/24), thanks [@engage-chancock](https://github.com/engage-chancock)!)
    - Allow passing a zipped backup
    - Fix issue with script requesting database name
- April 2023
  - DnnWebsiteManagement 1.7.1
    - Don't show warning about obsolete encrypt parameter
  - DnnWebsiteManagement 1.7.0
    - Don't encrypt connections to SQL Server
- December 2022
  - DnnWebsiteManagement 1.6.2
    - Fix issue creating a site from a version instead of a zip
- October 2022
  - BindingRedirects 0.1.2
    - Fix issue `web.config` contains `dependentAssembly` without `bindingRedirect` element (e.g. when `codeBase` element is used instead)
- September 2022
  - DnnWebsiteManagement 1.6.1
    - Fix issue when `GitRepository` is passed on Windows Powershell
    - Show progress when copying Git repository
    - Move files from site backup instead of copy and delete (when backup is a zip, not a folder)
  - DnnWebsiteManagement 1.6.0
    - Add `GitRepository` parameter to `New-DNNSite` and `Restore-DNNSite`
    - If `GitRepository` or `SiteZipPath` includes `.dnn-website-management/restore-site.ps1`, this script is called at the end of `Restore-DNNSite`
- August 2022
  - SslWebBinding 1.3.0
    - `New-SslWebBinding` will use `mkcert` to generate the certificate if installed
    - `Remove-SslWebBinding` correctly suppresses confirm prompt
  - DnnWebsiteManagement 1.4.2
    - Use SslWebBinding 1.3.0
  - DnnWebsiteManagement 1.4.3
    - Fix error when site zip has a single folder
  - DnnWebsiteManagement 1.4.4
    - Fix error when restoring newer Engage: AMS site
  - DnnWebsiteManagement 1.4.5
    - Remove extra confirmation prompts
  - DnnWebsiteManagement 1.5.0
    - Fail fast when unable to continue
    - Use standardized names (with aliases for backwards compatibility)
      - Rename `Upgrade-DNNSite` to `Update-DNNSite`
      - Rename `Install-DNNResources` to `Install-DNNResource`
      - Capitalize all parameters
      - Rename `siteName` to `Name`
      - Rename `siteZip` to `SiteZipPath`
      - Rename `oldDomain` to `Domain`
      - etc.
    - Implement ShouldProcess (i.e. `-WhatIf` and `-Confirm`) for `Rename-DNNSite` and `Update-DNNSite`
    - Support restoring when site zip includes development files (i.e. if the website folder is a level deeper but the top-level files should be kept)
    - Show progress when copying files and restoring database
  - DnnWebsiteManagement 1.5.1
    - Fix error when no database backup is passed
- July 2022
  - Recycle 1.5.0
    - Added `Restore-RecycledItem` and `Get-RecycledItem`
  - AdministratorRole 1.1.0
    - Added `Invoke-Elevated`
- April 2022
  - DnnWebsiteManagement 1.4.1
    - Fix errors introduced in 1.4.0 for `Restore-DNNSite`
  - DnnWebsiteManagement 1.4.0
    - Add more protection scripts when restoring
    - Update default DNN version to 9.10.2
    - Implement ShouldProcess (i.e. `-WhatIf` and `-Confirm`) for `New-DNNSite` and `Remove-DNNSite`
    - Use SqlServer module instead of SQLPS
    - Use IisAdministration module instead of WebAdministration
  - ACL-Permissions 1.1.0
    - Implement ShouldProcess (i.e. `-WhatIf` and `-Confirm`) for `Set-ModifyPermission`
    - Use IisAdministration module instead of WebAdministration
  - SslWebBinding 1.2.0
    - Implement ShouldProcess (i.e. `-WhatIf` and `-Confirm`) for `New-SslWebBinding` and `Remove-SslWebBinding`
    - Use IisAdministration module instead of WebAdministration
  - Add-HostFileEntry 1.1.0
    - Implement ShouldProcess (i.e. `-WhatIf` and `-Confirm`) for `Add-HostFileEntry` and `Remove-HostFileEntry`
- September 2021
  - Declare platform compatibility
    - ACL-Permissions 1.0.2
    - Add-HostFileEntry 1.0.4
    - AdministratorRole 1.0.1
    - BindingRedirects 0.1.1
    - DnnWebsiteManagement 1.3.1
    - Read-Choice 1.0.1
    - Recycle 1.3.1
    - SslWebBinding 1.1.2
    - Write-HtmlNode 2.0.1
- May 2021
  - Recycle 1.3.0
    - Add support for piping files into Remove-ItemSafely
- March 2021
  - DnnWebsiteManagement 1.3.0
    - Remove Application Insights config when restoring
  - Recycle 1.2.0
    - Add ShouldProcess (i.e. -WhatIf and -Confirm) support
  - Write-HtmlNode 2.0.0
    - Indicate it only supports Desktop edition (i.e. Windows Powershell vs. Powershell Core)
- October 2019
  - BindingRedirects 0.1.0
    - Initial version
- June 2019
  - DnnWebsiteManagement 1.2.4
    - Fix bugs extracting package and viewing zip error output
  - DnnWebsiteManagement 1.2.3
    - Fix failure to clean up extracted files after restore
  - DnnWebsiteManagement 1.2.2
    - Removed (hidden) dependency on PSCX
- February 2019
  - Add-HostFileEntry 1.0.2
    - Removed (hidden) dependency on PSCX
  - DnnWebsiteManagement 1.2.1
    - Removed dependency on PSCX
- August 2018
  - Recycle 1.1.1
    - Removed wildcard exports for increased performance and security
- July 2018
  - SslWebBinding 1.1.1
    - Removed duplicate host headers when generating binding and certificate
- Mar. 2018
  - Recycle 1.1.0
    - Added ability to remove files with special characters in path via `-LiteralPath` -parameter
    - Added ability to remove multiple files by passing a glob, e.g. `Remove-ItemSafely -Path *.txt`
- Nov. 2017
  - Added ability to generate HTTPS certificate with multiple domains in `SslWebBinding`
  - When restoring DNN site in `DnnWebsiteManagement`, generate single HTTPS certificate
- Oct. 2016
  - Added `Read-Choice` module
  - Added `Write-HtmlNode` module
  - Added `SslWebBinding` module
  - Added `AdministratorRole` module
  - Added `Add-HostFileEntry` module
  - Added `ACL-Permissions` module
  - Added `DnnWebsiteManagement` module
- Aug. 2016
  - Added `Recycle` module
