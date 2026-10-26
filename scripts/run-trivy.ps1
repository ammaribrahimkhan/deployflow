<#
Runs Trivy inside the pinned Docker image.

  -TrivyImage : pinned image reference (aquasec/trivy@sha256:...)
  -SourceDir  : host folder mounted at /work (the working directory; .trivyignore is read from here)
  -InputDir   : optional host folder mounted at /in (for image tarballs)
  -OutDir     : optional host folder mounted at /out (for reports)
  -TrivyArgs  : arguments passed to Trivy (for example "fs", "--severity", "HIGH")

The exit code of Trivy is returned to the caller.
#>
param(
  [Parameter(Mandatory = $true)] [string]$TrivyImage,
  [Parameter(Mandatory = $true)] [string]$SourceDir,
  [string]$InputDir,
  [string]$OutDir,
  [Parameter(Mandatory = $true)] [string[]]$TrivyArgs
)

if ($TrivyImage -like "*REPLACE_WITH_DIGEST*") {
  Write-Host "##vso[task.logissue type=error]The Trivy image digest is still the placeholder. Edit pipelines/variables.yml (see the Milestone 4 guide, Part 1)."
  exit 1
}

$cacheDir = "C:\trivy-cache"
if (-not (Test-Path $cacheDir)) {
  New-Item -ItemType Directory -Path $cacheDir | Out-Null
}

$dockerArgs = @("run", "--rm", "-v", "${cacheDir}:/root/.cache/", "-v", "${SourceDir}:/work", "-w", "/work")
if ($InputDir) { $dockerArgs += @("-v", "${InputDir}:/in") }
if ($OutDir) { $dockerArgs += @("-v", "${OutDir}:/out") }
$dockerArgs += $TrivyImage
$dockerArgs += $TrivyArgs

& docker @dockerArgs
exit $LASTEXITCODE