#Requires -Version 3
#Requires -Modules WebAdministration, AdministratorRole, PKI
Set-StrictMode -Version:Latest

Import-Module WebAdministration

function New-SslWebBinding {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string[]]$hostHeader
  );

  Assert-AdministratorRole

  if (-not $hostHeader) {
    $hostHeader = @($siteName)
  }

  $hostHeader = $hostHeader | Select-Object -Unique

  $existingBindings = @($hostHeader | Foreach-Object { Get-WebBinding -Name:$siteName -HostHeader:$_ -Protocol:https })
  if ($existingBindings.Length -eq $hostHeader.Length) {
    foreach ($existingBinding in $existingBindings) {
      $domain = $existingBinding.bindingInformation -replace '^.*:.*:',''
      Write-Warning "Binding for https://$domain to $siteName already exists"
    }
  } else {
    if ($existingBindings.Length -gt 0) {
      foreach ($existingBinding in $existingBindings) {
        $domain = $existingBinding.bindingInformation -replace '^.*:.*:',''
        Write-Warning "Removing binding for https://$domain to $siteName"
        Remove-WebBinding -Name:$siteName -HostHeader:$domain -Protocol:https
      }
    }

    foreach ($domain in $hostHeader) {
      Write-Host "Adding binding for https://$domain to $siteName"
      New-WebBinding -Name:$siteName -HostHeader:$domain -Protocol:https -SslFlags:1
    }
  }

  $existingCertBindings = @($hostHeader | Foreach-Object { Get-Item -Path:"IIS:\SslBindings\!443!$_" -ErrorAction SilentlyContinue })
  if ($existingCertBindings.Length -eq $hostHeader.Length) {
    foreach ($existingBinding in $existingBindings) {
      $domain = $existingBinding.bindingInformation -replace '^.*:.*:',''
      Write-Warning "Certificate binding for https://$domain already exists"
    }
  } else {
    if ($existingCertBindings.Length -gt 0) {
      foreach ($binding in $existingCertBindings) {
        Remove-Item -Path:"IIS:\SslBindings\!443!$($binding.Host)"
      }
    }

    $cert = New-SelfSignedCertificate -DnsName:$hostHeader -CertStoreLocation:'Cert:\LocalMachine\My'

    foreach ($domain in $hostHeader) {
      New-Item -Path:"IIS:\SslBindings\!443!$domain" -Value:$cert -SSLFlags:1
    }

    Write-Host "Trusting generated SSL certificate for $hostHeader" #based on https://stackoverflow.com/a/21001534
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store 'Root','CurrentUser'
    $store.Open('ReadWrite')
    $store.Add($cert)
    $store.Close()
  }

<#
.SYNOPSIS
    Adds an HTTPS binding to a website in IIS
.DESCRIPTION
    Generates a new self-signed SSL certificate and associates it with a new HTTPS binding in the given site, adding the certificate to the trusted certificate store on this machine
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER hostHeader
    The host header(s) for which to add the binding and certificate.   Defaults to $siteName
#>
}

function Remove-SslWebBinding {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string[]]$hostHeader
  );

  Assert-AdministratorRole

  if (-not $hostHeader) {
    $hostHeader = @($siteName)
  }

  foreach ($domain in $hostHeader) {
    Remove-Item -Path:"IIS:\SslBindings\!443!$domain" -ErrorAction:Continue
    Remove-WebBinding -Name:$siteName -HostHeader:$domain -Protocol:https -ErrorAction:Continue
  }

<#
.SYNOPSIS
    Removes an HTTPS binding to a website in IIS
.DESCRIPTION
    Removes an HTTPS binding in the given site
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.local)
.PARAMETER hostHeader
    The host header(s) for which to remove the binding.   Defaults to $siteName
#>
}

Export-ModuleMember New-SslWebBinding
Export-ModuleMember Remove-SslWebBinding
