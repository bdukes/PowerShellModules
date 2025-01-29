﻿#
# Module manifest for module 'DnnWebsiteManagement'
#
# Generated by: Brian Dukes
#
# Generated on: 10/10/2016
#

@{

    # Script module or binary module file associated with this manifest.
    RootModule        = 'DnnWebsiteManagement.psm1'

    # Version number of this module.
    ModuleVersion     = '2.0.7'

    # Supported PSEditions
    # CompatiblePSEditions = @()

    # ID used to uniquely identify this module
    GUID              = '53547b4e-358b-49ad-9e8b-7ea0ef271524'

    # Author of this module
    Author            = 'Brian Dukes'

    # Company or vendor of this module
    CompanyName       = 'Engage Software'

    # Copyright statement for this module
    Copyright         = '(c) 2025 Engage Software'

    # Description of the functionality provided by this module
    Description       = "A set of functions for managing websites built on the DNN Platform."

    # Minimum version of the Windows PowerShell engine required by this module
    PowerShellVersion = '5.0.0'

    # Name of the Windows PowerShell host required by this module
    # PowerShellHostName = ''

    # Minimum version of the Windows PowerShell host required by this module
    # PowerShellHostVersion = ''

    # Minimum version of Microsoft .NET Framework required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
    # DotNetFrameworkVersion = ''

    # Minimum version of the common language runtime (CLR) required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
    # CLRVersion = ''

    # Processor architecture (None, X86, Amd64) required by this module
    # ProcessorArchitecture = ''

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @( @{ ModuleName = 'AdministratorRole'; ModuleVersion = '1.1.0'; GUID = '694c2097-6b13-4735-8d6e-396224d646cc' },
        @{ ModuleName = 'Add-HostFileEntry'; ModuleVersion = '1.1.0'; GUID = '16e30c8c-8de5-4090-a542-e8f9594ca613' },
        @{ ModuleName = 'SslWebBinding'; ModuleVersion = '1.4.0'; GUID = 'd8b5b233-6f01-4ade-b771-147cc9101072' },
        @{ ModuleName = 'Write-HtmlNode'; ModuleVersion = '2.0.1'; GUID = '941aad91-17a6-43a5-bb1c-cce8526d7b3e' },
        @{ ModuleName = 'ACL-Permissions'; ModuleVersion = '1.1.0'; GUID = '908787a0-5a50-43c8-816a-7fa411b4e562' },
        @{ ModuleName = 'Read-Choice'; ModuleVersion = '1.0.2'; GUID = 'ebab63fa-f63d-427a-99c8-8450974b257c' },
        @{ ModuleName = 'SqlServer'; ModuleVersion = '21.1.18256' },
        @{ ModuleName = 'IISAdministration'; ModuleVersion = '1.1.0.0' } )

    # Assemblies that must be loaded prior to importing this module
    # RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    # ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    # TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    # FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    # NestedModules = @()

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = @('Install-DNNResource', 'Remove-DNNSite', 'Rename-DNNSite', 'New-DNNSite', 'Update-DNNSite', 'Restore-DNNSite')

    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport   = @()

    # DSC resources to export from this module
    # DscResourcesToExport = @()

    # List of all modules packaged with this module
    # ModuleList = @()

    # List of all files packaged with this module
    FileList          = 'DnnWebsiteManagement.psm1'

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData       = @{

        PSData = @{

            # Tags applied to this module. These help with module discovery in online galleries.
            Tags                       = @('PSEdition_Core', 'PSEdition_Desktop', 'Windows')

            # A URL to the license for this module.
            LicenseUri                 = 'https://github.com/bdukes/PowerShellModules/blob/main/LICENSE'

            # A URL to the main website for this project.
            ProjectUri                 = 'https://github.com/bdukes/PowerShellModules'

            # A URL to an icon representing this module.
            # IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes               = 'https://github.com/bdukes/PowerShellModules/blob/main/CHANGES.md'

            ExternalModuleDependencies = @()

        } # End of PSData hashtable

    } # End of PrivateData hashtable

    # HelpInfo URI of this module
    # HelpInfoURI = ''

    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
    # DefaultCommandPrefix = ''

}

