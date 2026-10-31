<#
Downloads the exact, pinned versions of the three browser libraries the dashboard uses and saves
them inside the repository (dashboard\web\vendor). The dashboard therefore never loads anything
from the internet at run time, and there is no npm and no build step.

  react      18.3.1
  react-dom  18.3.1
  htm        3.1.1   (tiny JSX-like templates for React, no compiler needed)

A SHA256SUMS.txt file is written so a change to any of these files shows up in Git.
#>
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "dashboard\web\vendor"
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

$files = @(
  @{ Name = "react.production.min.js";     Url = "https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js" },
  @{ Name = "react-dom.production.min.js"; Url = "https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js" },
  @{ Name = "htm.umd.js";                  Url = "https://cdn.jsdelivr.net/npm/htm@3.1.1/dist/htm.umd.js" }
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sums = @()

foreach ($file in $files) {
  $target = Join-Path $vendor $file.Name
  $ok = $false
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      Write-Host "Downloading $($file.Name) (attempt $attempt of 4)..."
      Invoke-WebRequest -Uri $file.Url -OutFile $target -UseBasicParsing -TimeoutSec 60
      if ((Get-Item $target).Length -gt 1000) { $ok = $true; break }
    } catch {
      Write-Host "  failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds (5 * $attempt)
  }
  if (-not $ok) {
    Write-Host "Could not download $($file.Name). Check your internet connection and run this script again."
    exit 1
  }
  $hash = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLower()
  $sums += "$hash  $($file.Name)"
}

$sums | Set-Content -Path (Join-Path $vendor "SHA256SUMS.txt") -Encoding ascii
Write-Host ""
Write-Host "Done. Files in ${vendor}:"
Get-ChildItem $vendor | Select-Object Name, Length | Format-Table -AutoSize
Get-Content (Join-Path $vendor "SHA256SUMS.txt")