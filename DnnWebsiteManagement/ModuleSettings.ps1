# ---------------------------------------------------------------------------
# You can override individual settings by passing a hashtable with just those
# settings defined as shown below:
#
#     Import-Module dnnwebsitemanagement -arg @{defaultVersion = "9.2.2"}
#
# Any value not specified will be retrieved from the default settings built
# into the DnnWebsiteManagement module manifest.
#
# If you have a sufficiently large number of altered setting, copy this file,
# modify it and pass the path to your settings file to Import-Module e.g.:
#
#     Import-Module dnnwebsitemanagement -arg "$(Split-Path $profile -parent)\ModuleSettings.ps1"
#
# ---------------------------------------------------------------------------
@{
    DefaultVersion = "9.1.0"

    DefaultIncludeSource = $true 

    WebHome = "C:\inetpub\wwwroot" 

    DnnPackages = "${Env:ProgramFiles(x86)}\nvisionative\nvQuickSite\Downloads"
	
	Browser = "Chrome"                            # The default browser used when calling Start-Browser
}