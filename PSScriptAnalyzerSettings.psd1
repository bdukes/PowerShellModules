# Settings for PSScriptAnalyzer invocation.
# based on https://devblogs.microsoft.com/powershell/using-psscriptanalyzer-to-check-powershell-version-compatibility/
@{
    Rules=@{
        PSUseCompatibleCommands=@{
            Enable=$true
            TargetProfiles=@(
                'win-8_x64_10.0.17763.0_6.1.3_x64_4.0.30319.42000_core', # PS 6.1, Server 2019
                'win-48_x64_10.0.17763.0_6.1.3_x64_4.0.30319.42000_core', # PS 6.1, Windows 10
                'ubuntu_x64_18.04_6.1.3_x64_4.0.30319.42000_core', # PS 6.1, Ubuntu
                'win-8_x64_10.0.14393.0_5.1.14393.2791_x64_4.0.30319.42000_framework', # PS 5.1, Server 2016
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework', # PS 5.1, Windows 10
                'win-8_x64_6.3.9600.0_4.0_x64_4.0.30319.42000_framework', # PS 4.0, Server 2012R2
                'win-8_x64_6.2.9200.0_3.0_x64_4.0.30319.42000_framework' # PS 3.0, Server 2012
            )
        }
        PSUseCompatibleSyntax=@{
            Enable=$true
            TargetVersions=@(
                '6.1',
                '5.1',
                '4.0',
                '3.0'
            )
        }
    }
}
