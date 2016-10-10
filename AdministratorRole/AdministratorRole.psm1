Set-StrictMode -Version Latest

function Test-AdministratorRole {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
  return $isAdmin

<#
.SYNOPSIS
    Gets a value indicating whether the current user is an administrator.
.DESCRIPTION
    Returns $True or $False, depending on whether the current user is in the built-in Administatrators role
.OUTPUTS
    System.Boolean. Returns a value indicating whether the current user is a administrator
#>
}

function Assert-AdministratorRole {
  param(
    [parameter(position=0)]
    [string]$errorMessage = "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
  );

  $isAdmin = (Test-AdministratorRole)
  if (-not $isAdmin) {
    throw $errorMessage
  }

<#
.SYNOPSIS
    Asserts that the current user is an administrator.  Throws an error if not.
.DESCRIPTION
    Checks whether the current user is in the built-in Administrator role, and throws an error message if not.
.PARAMETER errorMessage
    The message to throw when the user is not an administrator
#>
}

Export-ModuleMember Test-AdministratorRole
Export-ModuleMember Assert-AdministratorRole