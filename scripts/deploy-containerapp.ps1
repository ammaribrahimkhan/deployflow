<#
Deploys an image (by DIGEST) to a Container App and writes a promotion record.
Runs inside an AzureCLI@2 task, so `az` is already signed in with the service connection.

  -AppName / -ResourceGroup : the Container App to update
  -EnvironmentName          : "staging" or "production" (used in the record)
  -MetadataPath             : release-metadata.json produced by the CI pipeline
  -RevisionSuffix           : unique name part for the new revision
  -OutputPath               : where to write the promotion record JSON
  -RunUrl                   : link to this pipeline run (stored in the record)
  -RequiredRecordPath       : optional promotion record from the previous environment;
                              the digest must be identical (staging -> production)

The script never builds an image. It refuses to deploy anything whose security gate did not pass.
#>
param(
  [Parameter(Mandatory = $true)] [string]$AppName,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$EnvironmentName,
  [Parameter(Mandatory = $true)] [string]$MetadataPath,
  [Parameter(Mandatory = $true)] [string]$RevisionSuffix,
  [Parameter(Mandatory = $true)] [string]$OutputPath,
  [string]$RunUrl = "",
  [string]$RequiredRecordPath = ""
)

function Fail($message) {
  Write-Host "##vso[task.logissue type=error]$message"
  exit 1
}

# 1. Read and validate the release metadata from CI.
if (-not (Test-Path $MetadataPath)) { Fail "release-metadata.json not found at $MetadataPath" }
$meta = Get-Content $MetadataPath -Raw | ConvertFrom-Json

if ($meta.security.gateResult -ne "passed") { Fail "The security gate did not pass for this image. Refusing to deploy." }
if ($meta.branch -ne "main") { Fail "This image was built from branch '$($meta.branch)'. Only builds from main can be deployed." }

$imageRef = $meta.imageReference
if (-not $imageRef -or $imageRef -notmatch "@sha256:") { Fail "release-metadata.json has no image digest reference" }
$digest = $imageRef.Split("@")[1]

# 2. Production rule: it must be exactly the digest that was verified in staging.
if ($RequiredRecordPath) {
  if (-not (Test-Path $RequiredRecordPath)) { Fail "The previous environment's promotion record was not found: $RequiredRecordPath" }
  $required = Get-Content $RequiredRecordPath -Raw | ConvertFrom-Json
  if ($required.imageReference -ne $imageRef) {
    Fail "Digest mismatch. The previous environment verified '$($required.imageReference)' but this run wants to deploy '$imageRef'."
  }
  Write-Host "Digest matches the one verified in the previous environment."
}

# 3. The image must exist in the registry.
$registryHost = $imageRef.Split("/")[0]
$registryName = $registryHost.Split(".")[0]
$repoAndDigest = $imageRef.Substring($registryHost.Length + 1)
az acr repository show --name $registryName --image $repoAndDigest --query digest -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Image $imageRef was not found in the registry $registryName" }

# 4. What is running now?
$beforeText = (az containerapp show --name $AppName --resource-group $ResourceGroup --query "{revision:properties.latestRevisionName, image:properties.template.containers[0].image}" -o json | Out-String)
if ($LASTEXITCODE -ne 0) { Fail "Could not read the container app $AppName. Does it exist, and does the pipeline identity have access to $ResourceGroup?" }
$before = ConvertFrom-Json $beforeText
Write-Host "Currently running: revision $($before.revision), image $($before.image)"

# 5. Deploy (skipped when this exact image is already the live one: idempotent).
$alreadyDeployed = ($before.image -eq $imageRef)
if ($alreadyDeployed) {
  Write-Host "This exact image is already deployed to $AppName. Skipping the update."
} else {
  Write-Host "Deploying $imageRef to $AppName (revision suffix $RevisionSuffix)..."
  az containerapp update --name $AppName --resource-group $ResourceGroup --image $imageRef --revision-suffix $RevisionSuffix --output none
  if ($LASTEXITCODE -ne 0) { Fail "az containerapp update failed" }
}

# 6. Confirm what is deployed now.
$afterText = (az containerapp show --name $AppName --resource-group $ResourceGroup --query "{fqdn:properties.configuration.ingress.fqdn, revision:properties.latestRevisionName, image:properties.template.containers[0].image, state:properties.provisioningState}" -o json | Out-String)
if ($LASTEXITCODE -ne 0) { Fail "Could not read the container app after deployment" }
$after = ConvertFrom-Json $afterText

if ($after.state -ne "Succeeded") { Fail "Container app provisioning state is '$($after.state)', expected 'Succeeded'" }
if ($after.image -ne $imageRef) { Fail "The app runs '$($after.image)' but '$imageRef' was expected" }
Write-Host "Deployed: revision $($after.revision), image $($after.image)"

# 7. Write the promotion record.
$appUrl = "https://" + $after.fqdn
$record = [ordered]@{
  environment          = $EnvironmentName
  appName              = $AppName
  resourceGroup        = $ResourceGroup
  imageReference       = $imageRef
  imageDigest          = $digest
  shortSha             = $meta.shortSha
  gitSha               = $meta.gitSha
  appVersion           = $meta.appVersion
  sourceBuildId        = $meta.buildId
  sourcePipelineRunUrl = $meta.pipelineRunUrl
  previousRevision     = $before.revision
  previousImage        = $before.image
  newRevision          = $after.revision
  alreadyDeployed      = $alreadyDeployed
  url                  = $appUrl
  deployedAtUtc        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  deploymentRunUrl     = $RunUrl
}

$folder = Split-Path -Parent $OutputPath
if ($folder -and -not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($record | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

Write-Host "##vso[task.setvariable variable=appUrl]$appUrl"
Write-Host "##vso[task.setvariable variable=shortSha]$($meta.shortSha)"
Write-Host "##vso[task.setvariable variable=promotionReady]true"
exit 0