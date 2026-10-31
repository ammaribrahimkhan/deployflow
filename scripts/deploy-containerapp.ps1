
<#
Deploys an immutable image digest to an Azure Container App
and writes a promotion record.

Runs inside AzureCLI@2, where Azure CLI is already authenticated.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$MetadataPath,

    [Parameter(Mandatory = $true)]
    [string]$RevisionSuffix,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$RunUrl = "",

    [string]$RequiredRecordPath = ""
)

$ErrorActionPreference = "Stop"

function Fail($message) {
    Write-Host "##vso[task.logissue type=error]$message"
    exit 1
}

# 1. Read and validate CI release metadata.

if (-not (Test-Path -LiteralPath $MetadataPath)) {
    Fail "release-metadata.json not found at $MetadataPath"
}

try {
    $meta = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Could not parse release-metadata.json."
}

if ($meta.security.gateResult -ne "passed") {
    Fail "The security gate did not pass. Refusing to deploy."
}

if ($meta.branch -ne "main") {
    Fail "This image was built from '$($meta.branch)'. Only main can be deployed."
}

$imageRef = [string]$meta.imageReference

if ($imageRef -notmatch '^.+@sha256:[a-fA-F0-9]{64}$') {
    Fail "release-metadata.json does not contain a valid image digest reference."
}

$digest = $imageRef.Split("@")[1]

# 2. Verify the digest against the previous environment.

if (-not [string]::IsNullOrWhiteSpace($RequiredRecordPath)) {

    if (-not (Test-Path -LiteralPath $RequiredRecordPath)) {
        Fail "Previous environment promotion record not found: $RequiredRecordPath"
    }

    try {
        $required = Get-Content -LiteralPath $RequiredRecordPath -Raw | ConvertFrom-Json
    }
    catch {
        Fail "Could not parse previous environment promotion record."
    }

    if ($required.imageReference -ne $imageRef) {
        Fail "Digest mismatch. Previous environment verified '$($required.imageReference)' but this deployment wants '$imageRef'."
    }

    if ($required.outcome -and $required.outcome -notin @("promoted", "already_live")) {
        Fail "Previous environment did not successfully promote this image. Outcome: $($required.outcome)"
    }

    Write-Host "Digest matches the image verified in the previous environment."
}

# 3. Verify the image exists in ACR.

$registryHost = $imageRef.Split("/")[0]
$registryName = $registryHost.Split(".")[0]
$repoAndDigest = $imageRef.Substring($registryHost.Length + 1)

$verifiedDigest = & az acr repository show `
    --name $registryName `
    --image $repoAndDigest `
    --query digest `
    -o tsv

if ($LASTEXITCODE -ne 0) {
    Fail "Image $imageRef was not found in registry $registryName."
}

$verifiedDigest = ([string]$verifiedDigest).Trim()

if ($verifiedDigest -ne $digest) {
    Fail "ACR digest verification failed. Expected $digest but received $verifiedDigest."
}

Write-Host "ACR digest verified: $verifiedDigest"

# 4. Read the currently deployed app state.

$beforeText = & az containerapp show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --query "{revision:properties.latestRevisionName,image:properties.template.containers[0].image}" `
    -o json

if ($LASTEXITCODE -ne 0) {
    Fail "Could not read Container App $AppName. Check its existence and pipeline permissions."
}

try {
    $before = $beforeText | Out-String | ConvertFrom-Json
}
catch {
    Fail "Could not parse the current Container App state."
}

Write-Host "Currently deployed revision: $($before.revision)"
Write-Host "Currently deployed image: $($before.image)"

# 5. Deploy the image, unless it is already deployed.

$alreadyDeployed = ($before.image -eq $imageRef)

if ($alreadyDeployed) {

    Write-Host "This exact image is already deployed. Skipping update."

}
else {

    Write-Host "Deploying $imageRef"
    Write-Host "Revision suffix: $RevisionSuffix"

    & az containerapp update `
        --name $AppName `
        --resource-group $ResourceGroup `
        --image $imageRef `
        --revision-suffix $RevisionSuffix `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Fail "az containerapp update failed."
    }
}

# 6. Verify the deployed image and provisioning state.

$afterText = & az containerapp show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --query "{fqdn:properties.configuration.ingress.fqdn,revision:properties.latestRevisionName,image:properties.template.containers[0].image,state:properties.provisioningState}" `
    -o json

if ($LASTEXITCODE -ne 0) {
    Fail "Could not read Container App after deployment."
}

try {
    $after = $afterText | Out-String | ConvertFrom-Json
}
catch {
    Fail "Could not parse Container App state after deployment."
}

if ($after.state -ne "Succeeded") {
    Fail "Container App provisioning state is '$($after.state)', expected 'Succeeded'."
}

if ($after.image -ne $imageRef) {
    Fail "The app runs '$($after.image)' but '$imageRef' was expected."
}

if ([string]::IsNullOrWhiteSpace($after.fqdn)) {
    Fail "Container App ingress FQDN is missing."
}

Write-Host "Deployment verified."
Write-Host "Revision: $($after.revision)"
Write-Host "Image: $($after.image)"

# 7. Write the promotion record.

$appUrl = "https://$($after.fqdn)"

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
    outcome              = "promoted"
    url                  = $appUrl
    deployedAtUtc        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    deploymentRunUrl     = $RunUrl
}

$folder = Split-Path -Parent $OutputPath

if ($folder -and -not (Test-Path -LiteralPath $folder)) {
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
}

[System.IO.File]::WriteAllText(
    $OutputPath,
    ($record | ConvertTo-Json -Depth 8),
    (New-Object System.Text.UTF8Encoding $false)
)

Write-Host "##vso[task.setvariable variable=appUrl]$appUrl"
Write-Host "##vso[task.setvariable variable=shortSha]$($meta.shortSha)"
Write-Host "##vso[task.setvariable variable=promotionReady]true"

Write-Host "Staging deployment promotion record created successfully."

exit 0
