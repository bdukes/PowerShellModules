#Requires -Version 3
#Requires -Modules IISAdministration, AdministratorRole, PKI
Set-StrictMode -Version:Latest

Import-Module IISAdministration

function getHostHeader([string]$bindingInformation) {
  return $bindingInformation.Substring($bindingInformation.LastIndexOf(':') + 1);
}
function getPort([string]$bindingInformation) {
  $firstSeparatorIndex = $bindingInformation.IndexOf(':');
  return $bindingInformation.Substring($firstSeparatorIndex + 1, $bindingInformation.LastIndexOf(':') - $firstSeparatorIndex - 1);
}

function New-SslWebBinding {
  param(
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $false, position = 1)]
    [string[]]$hostHeader
  );

  Assert-AdministratorRole

  if (-not $hostHeader) {
    $hostHeader = @($siteName)
  }

  $hostHeader = $hostHeader | Select-Object -Unique

  $existingBindings = @($hostHeader | Foreach-Object { Get-IISSiteBinding -Name:$siteName -Protocol:https } | Where-Object { getHostHeader($_.BindingInformation) -eq $_ });
  if ($existingBindings.Length -eq $hostHeader.Length) {
    foreach ($existingBinding in $existingBindings) {
      $domain = getHostHeader($existingBinding.bindingInformation);
      Write-Warning "Binding for https://$domain to $siteName already exists";
    }
  }
  else {
    if ($existingBindings.Length -gt 0) {
      foreach ($existingBinding in $existingBindings) {
        $domain = getHostHeader($existingBinding.bindingInformation);
        Write-Warning "Removing binding for https://$domain to $siteName";
        Remove-IISSiteBinding -Name:$siteName -BindingInformation:$existingBinding.bindingInformation -Protocol:https;
      }
    }

    foreach ($domain in $hostHeader) {
      Write-Information "Trusting generated SSL certificate for $hostHeader"; #based on https://stackoverflow.com/a/21001534
      $cert = New-SelfSignedCertificate -DnsName:$hostHeader -CertStoreLocation:'Cert:\LocalMachine\My'
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store 'Root', 'CurrentUser';
      $store.Open('ReadWrite');
      $store.Add($cert);
      $store.Close();

      Write-Information "Adding binding for https://$domain to $siteName";
      New-IISSiteBinding -Name:$siteName -BindingInformation:"*:443:$domain" -Protocol:https -SslFlag:'Sni' -CertificateThumbPrint:$cert.Thumbprint -CertStoreLocation:'Cert:\LocalMachine\My';
    }
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
    [parameter(Mandatory = $true, position = 0)]
    [string]$siteName,
    [parameter(Mandatory = $false, position = 1)]
    [string[]]$hostHeader
  );

  Assert-AdministratorRole

  if (-not $hostHeader) {
    $hostHeader = @($siteName)
  }

  foreach ($existingBinding in @($hostHeader | Foreach-Object { Get-IISSiteBinding -Name:$siteName -Protocol:https } | Where-Object { getHostHeader($_.BindingInformation) -eq $_ })) {
    Remove-IISSiteBinding -Name:$siteName -BindingInformation:$existingBinding.BindingInformation -Protocol:https -ErrorAction:Continue;
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
