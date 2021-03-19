#Requires -Modules AdministratorRole
Set-StrictMode -Version Latest

function Repair-AclCorruption {
    param(
        [parameter(Mandatory = $true, position = 0)]$directory);

    $out = icacls "$directory" /verify /t /q

    foreach ($line in $out) {
        if ($line -match '(.:[^:]*): (.*)') {
            $path = $Matches[1]
            Set-Acl $path (Get-Acl $path)
        }
    }
    <#
.SYNOPSIS
    Fixes ACLs on the directory (and its ancestors) that have become corrupted
.DESCRIPTION
    When the error message "This access control list is not in canonical form and therefore cannot be modified." comes up, you can use this to fix the ACLs
    Based on https://gist.github.com/vbfox/8fbec5c60b0c16289023, found from http://serverfault.com/a/287702/4110
.PARAMETER directory
    The path to the directory to which to apply permissions
.PARAMETER username
    The username of the account to which to give permissions
.PARAMETER domain
    The domain of the account to which to give permissions, defaults to the App Pool Identity domain
#>
}

function Set-ModifyPermission {
    param(
        [parameter(Mandatory = $true, position = 0)]$directory,
        [parameter(Mandatory = $true, position = 1)]$username,
        $domain = 'IIS APPPOOL');

    Assert-AdministratorRole

    $inherit = [system.security.accesscontrol.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $propagation = [system.security.accesscontrol.PropagationFlags]"None"

    if ($domain -eq 'IIS APPPOOL') {
        Import-Module WebAdministration
        $sid = (Get-ItemProperty IIS:\AppPools\$username).ApplicationPoolSid
        $identifier = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $user = $identifier.Translate([System.Security.Principal.NTAccount])
    }
    else {
        $user = New-Object System.Security.Principal.NTAccount($domain, $username)
    }

    $accessrule = New-Object system.security.AccessControl.FileSystemAccessRule($user, "Modify", $inherit, $propagation, "Allow")

    Repair-AclCorruption $directory
    $acl = Get-Acl $directory
    $acl.AddAccessRule($accessrule)
    set-acl -aclobject $acl $directory
    <#
.SYNOPSIS
    Gives the given user the modify permission to the given directory
.PARAMETER directory
    The path to the directory to which to apply permissions
.PARAMETER username
    The username of the account to which to give permissions
.PARAMETER domain
    The domain of the account to which to give permissions, defaults to the App Pool Identity domain
#>
}

Export-ModuleMember Set-ModifyPermission
Export-ModuleMember Repair-AclCorruption
