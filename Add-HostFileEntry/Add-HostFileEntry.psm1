#Requires -Version 3
#Requires -Modules AdministratorRole
Set-StrictMode -Version:Latest

function Add-HostFileEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [parameter(Mandatory = $true, position = 0)]
        [string]$hostName,
        [string]$ipAddress = '127.0.0.1'
    );
    Assert-AdministratorRole;

    $hostsLocation = "$env:windir\System32\drivers\etc\hosts";
    $hostsContent = Get-Content -Path $hostsLocation -Raw;

    $ipRegex = [regex]::Escape($ipAddress);
    $hostRegex = [regex]::Escape($hostName);

    $existingEntry = $hostsContent -match "(?:`n|\A)\s*$ipRegex\s+$hostRegex\s*(?:`n|\Z)";
    if (-not $existingEntry) {
        if ($hostsContent -notmatch "`n\s*$") {
            # Add line break if missing from last line
            if ($PSCmdlet.ShouldProcess($hostsLocation, 'Add Blank Line')) {
                Add-Content -Path $hostsLocation -Value '';
            }
        }

        if ($PSCmdlet.ShouldProcess($hostsLocation, "Add entry mapping $hostName to $ipAddress")) {
            Add-Content -Path $hostsLocation -Value "$ipAddress`t`t$hostName";
        }
    }
    else {
        Write-Verbose -Message "Entry mapping $hostName to $ipAddress already exists in $hostsLocation";
    }
    <#
.SYNOPSIS
    Adds an entry to the HOSTS file
.DESCRIPTION
    If it doesn't already exist, adds a line to the HOSTS file mapping the given host name to the given IP address
.PARAMETER hostName
    The host name to map
.PARAMETER ipAddress
    The IP address to map
#>
}

function Remove-HostFileEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [parameter(Mandatory = $true, position = 0)]
        [string]$hostName,
        [string]$ipAddress = '127.0.0.1'
    );
    Assert-AdministratorRole;

    $hostsLocation = "$env:windir\System32\drivers\etc\hosts";

    $ipRegex = [regex]::Escape($ipAddress);
    $hostRegex = [regex]::Escape($hostName);

    $oldHostsContent = Get-Content -Path $hostsLocation -Raw
    $newHostsFileContent = $oldHostsContent | ForEach-Object { $_ -replace "(?:`n|\A)\s*$ipRegex\s+$hostRegex\s*(?:`n|\Z)", "`n" };

    if ($PSCmdlet.ShouldProcess($hostsLocation, "Remove entry mapping $hostName to $ipAddress")) {
        [System.IO.File]::WriteAllText($hostsLocation, $newHostsFileContent);
    }
    <#
.SYNOPSIS
    Removes an entry from the HOSTS file
.DESCRIPTION
    Updates the HOSTS file to remove a line mapping the given host name to the given IP address
.PARAMETER hostName
    The host name to remove
.PARAMETER ipAddress
    The IP address to remove
#>
}

Export-ModuleMember -Function Add-HostFileEntry;
Export-ModuleMember -Function Remove-HostFileEntry;
