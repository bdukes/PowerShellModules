Set-StrictMode -Version Latest

function Sync-BindingRedirect {
  param(
    [parameter(position=0)]
    [string]$webConfigPath
  );

  if (-not (Test-Path $webConfigPath -PathType Leaf)) {
    if ($webConfigPath -eq '') {
      $webConfigPath = 'web.config';
    } else {
      $webConfigPath = Join-Path $webConfigPath 'web.config';
    }
  }

  if (-not (Test-Path $webConfigPath -PathType Leaf)) {
    throw '$webConfigPath did not point to a web.config file';
  }

  $webConfigPath = (Get-Item $webConfigPath).FullName;
  $websitePath = Split-Path $webConfigPath;
  $binPath = Join-Path $websitePath 'bin';

  [xml]$config = Get-Content $webConfigPath;

  $assemblies = @($config.configuration.runtime.assemblyBinding.GetElementsByTagName("dependentAssembly") | Where-Object {
    $assemblyFileName = "$($_.assemblyIdentity.name).dll";
    $path = Join-Path $binPath $assemblyFileName;
    (test-path $path) -and ([System.Reflection.AssemblyName]::GetAssemblyName($path).Version.ToString() -ne $_.bindingRedirect.newVersion);
  });

  foreach ($assembly in $assemblies) {
    $assemblyFileName = "$($assembly.assemblyIdentity.name).dll";
    $path = Join-Path $binPath $assemblyFileName;
    $assembly.bindingRedirect.newVersion = [System.Reflection.AssemblyName]::GetAssemblyName($path).Version.ToString();
  }

  if ($assemblies.Length -gt 0) {
    $config.Save($webConfigPath);
    Write-Output "Updated $($assemblies.Length) assemblies"
  }
  else {
    Write-Warning 'No mismatched assemblies found'
  }

<#
.SYNOPSIS
    Updates the binding redirects in the web.config to match the assemblies in the bin folder
.DESCRIPTION
    For every dependentAssembly element in the web.config, finds the matching assembly in the bin folder, and updates the newVersion attribute to match the version of the assembly file
.PARAMETER webConfigPath
    The path to the website's web.config file
#>
}

Export-ModuleMember Sync-BindingRedirect
