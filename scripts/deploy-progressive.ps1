<#
Progressive production deployment with automatic rollback.

Flow:
  1. Validate the CI release metadata (security gate passed, built from main, digest present)
     and check the digest equals the one verified in staging.
  2. Find the known-good revision (the one with 100% of the traffic) and pin traffic to it.
  3. Create the candidate revision from the image digest. It receives 0% of the traffic.
  4. Pre-traffic smoke test directly against the candidate's own URL.
  5. Canary: shift traffic in steps (default 10, 50, 100). After each step, probe the live URL
     and the candidate directly. Too many errors or too much latency triggers an automatic rollback.
  6. On success keep the previous revision active (fast rollback); deactivate older ones.

Every outcome writes a record JSON. Re-running for an image that is already live is a no-op
unless -ForceRedeploy true is given.

Runs inside an AzureCLI@2 task, so `az` is already signed in.
#>
param(
  [Parameter(Mandatory = $true)] [string]$AppName,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$EnvironmentName,
  [Parameter(Mandatory = $true)] [string]$MetadataPath,
  [Parameter(Mandatory = $true)] [string]$RevisionSuffix,
  [Parameter(Mandatory = $true)] [string]$OutputPath,
  [string]$RunUrl = "",
  [string]$RequiredRecordPath = "",
  [string]$ExpectedEnvironment = "prod",
  [string]$Steps = "10,50,100",
  [int]$ObserveSeconds = 45,
  [int]$ProbesPerStep = 30,
  [double]$MaxErrorRatePercent = 5,
  [int]$PreTrafficMaxP95Ms = 1500,
  [int]$CanaryMaxP95Ms = 1500,
  [int]$InjectFaultPercent = 0,
  [string]$ForceRedeploy = "false"
)

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$force = ($ForceRedeploy -eq "true")

function Fail($message) {
  Write-Host "##vso[task.logissue type=error]$message"
  exit 1
}

# ---------------------------------------------------------------- helpers
function Invoke-Probe($url) {
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $ok = $false
  $revision = $null
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200) {
      $ok = $true
      try { $revision = ($response.Content | ConvertFrom-Json).revision } catch { $revision = $null }
    }
  } catch {
    $ok = $false
  }
  $stopwatch.Stop()
  return [pscustomobject]@{ Ok = $ok; Ms = [int]$stopwatch.ElapsedMilliseconds; Revision = $revision }
}

function Get-P95($values) {
  $sorted = @($values | Sort-Object)
  if ($sorted.Count -eq 0) { return 0 }
  $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
  return [int]$sorted[$index]
}

function Get-Traffic {
  $text = (az containerapp ingress traffic show --name $AppName --resource-group $ResourceGroup -o json | Out-String)
  if ($LASTEXITCODE -ne 0) { return @() }
  $items = ConvertFrom-Json $text
  return @($items)
}

function Deactivate-Revision($name) {
  az containerapp revision deactivate --name $AppName --resource-group $ResourceGroup --revision $name --output none
}

function Finish($outcome, $exitCode, $message) {
  $record.outcome = $outcome
  $record.message = $message
  $record.steps = $stepResults
  $record.finishedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  [System.IO.File]::WriteAllText($OutputPath, ($record | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "##vso[task.setvariable variable=promotionReady]true"
  Write-Host ""
  Write-Host "OUTCOME: $outcome"
  if ($exitCode -ne 0) {
    Write-Host "##vso[task.logissue type=error]$message"
  } else {
    Write-Host $message
  }
  exit $exitCode
}

function Restore-Traffic {
  # Idempotent: sending 100% to the known-good revision twice changes nothing.
  Write-Host "Restoring 100% of the traffic to the known-good revision $old ..."
  az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight "$old=100" --output none
  $restoreOk = ($LASTEXITCODE -eq 0)
  Deactivate-Revision $new
  $check = Get-Traffic | Where-Object { $_.revisionName -eq $old -and $_.weight -eq 100 }
  return ($restoreOk -and [bool]$check)
}

# ---------------------------------------------------------------- 1. validate the release
if (-not (Test-Path $MetadataPath)) { Fail "release-metadata.json not found at $MetadataPath" }
$meta = Get-Content $MetadataPath -Raw | ConvertFrom-Json

if ($meta.security.gateResult -ne "passed") { Fail "The security gate did not pass for this image. Refusing to deploy." }
if ($meta.branch -ne "main") { Fail "This image was built from branch '$($meta.branch)'. Only builds from main can be deployed." }

$imageRef = $meta.imageReference
if (-not $imageRef -or $imageRef -notmatch "@sha256:") { Fail "release-metadata.json has no image digest reference" }
$digest = $imageRef.Split("@")[1]

if ($RequiredRecordPath) {
  if (-not (Test-Path $RequiredRecordPath)) { Fail "The staging promotion record was not found: $RequiredRecordPath" }
  $required = Get-Content $RequiredRecordPath -Raw | ConvertFrom-Json
  if ($required.imageReference -ne $imageRef) {
    Fail "Digest mismatch. Staging verified '$($required.imageReference)' but this run wants to deploy '$imageRef'."
  }
  Write-Host "Digest matches the one verified in staging."
}

$stepList = @($Steps.Split(",") | ForEach-Object { [int]($_.Trim()) })
if ($stepList.Count -eq 0 -or $stepList[$stepList.Count - 1] -ne 100) { Fail "-Steps must end with 100 (for example 10,50,100)" }

$registryHost = $imageRef.Split("/")[0]
$registryName = $registryHost.Split(".")[0]
$repoAndDigest = $imageRef.Substring($registryHost.Length + 1)
az acr repository show --name $registryName --image $repoAndDigest --query digest -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Image $imageRef was not found in the registry $registryName" }

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$stepResults = @()
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
  strategy             = "progressive: $Steps"
  injectFaultPercent   = $InjectFaultPercent
  forceRedeploy        = $force
  outcome              = "started"
  message              = ""
  previousRevision     = $null
  previousImage        = $null
  candidateRevision    = $null
  steps                = @()
  finalTraffic         = $null
  startedAtUtc         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  finishedAtUtc        = $null
  deploymentRunUrl     = $RunUrl
}

# ---------------------------------------------------------------- 2. known-good revision
$stateText = (az containerapp show --name $AppName --resource-group $ResourceGroup --query "{latest:properties.latestRevisionName, traffic:properties.configuration.ingress.traffic, fqdn:properties.configuration.ingress.fqdn}" -o json | Out-String)
if ($LASTEXITCODE -ne 0) { Fail "Could not read the container app $AppName. Does it exist, and does the pipeline identity have access to $ResourceGroup?" }
$state = ConvertFrom-Json $stateText

$mainUrl = "https://" + $state.fqdn
Write-Host "##vso[task.setvariable variable=appUrl]$mainUrl"
Write-Host "##vso[task.setvariable variable=shortSha]$($meta.shortSha)"

$full = @($state.traffic) | Where-Object { $_.weight -eq 100 } | Select-Object -First 1
if (-not $full) {
  Fail "Production traffic is currently split across revisions (an earlier release may have been interrupted). Run the deployflow-rollback pipeline first to restore a single known-good revision."
}
$old = $state.latest
if ($full.revisionName) { $old = $full.revisionName }

$oldImage = (az containerapp revision show --name $AppName --resource-group $ResourceGroup --revision $old --query "properties.template.containers[0].image" -o tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $oldImage) { Fail "Could not read the image of the known-good revision $old" }

$record.previousRevision = $old
$record.previousImage = $oldImage
Write-Host "Known-good revision: $old"
Write-Host "Known-good image:    $oldImage"
Write-Host "Release image:       $imageRef"

if (($oldImage -eq $imageRef) -and (-not $force)) {
  $record.candidateRevision = $old
  Finish "already_live" 0 "This exact image is already live in $AppName. Nothing to deploy. (Use forceProductionRedeploy to redeploy it anyway.)"
}

# ---------------------------------------------------------------- 3. pin traffic, create the candidate
Write-Host "Pinning 100% of the traffic to $old before creating the candidate..."
az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight "$old=100" --output none
if ($LASTEXITCODE -ne 0) { Finish "failed_before_deploy" 1 "Could not pin the traffic to the known-good revision. Nothing was changed." }

Write-Host "Creating candidate revision (suffix $RevisionSuffix) from $imageRef ..."
az containerapp update --name $AppName --resource-group $ResourceGroup --image $imageRef --revision-suffix $RevisionSuffix --set-env-vars "FAULT_INJECTION_PERCENT=$InjectFaultPercent" --output none
if ($LASTEXITCODE -ne 0) { Finish "failed_before_traffic" 1 "az containerapp update failed. Production traffic is unchanged ($old = 100%)." }

$candText = (az containerapp show --name $AppName --resource-group $ResourceGroup --query "{latest:properties.latestRevisionName, fqdn:properties.latestRevisionFqdn}" -o json | Out-String)
$cand = ConvertFrom-Json $candText
$new = $cand.latest
$record.candidateRevision = $new

if (-not $new -or $new -eq $old -or -not $cand.fqdn) {
  Finish "failed_before_traffic" 1 "The candidate revision could not be identified (latest='$new', url='$($cand.fqdn)'). Production traffic is unchanged ($old = 100%)."
}
$candUrl = "https://" + $cand.fqdn
Write-Host "Candidate revision: $new"
Write-Host "Candidate URL:      $candUrl (0% of the traffic)"

# ---------------------------------------------------------------- 4. pre-traffic smoke test
Write-Host ""
Write-Host "=== Pre-traffic smoke test (the candidate has no user traffic yet) ==="
& (Join-Path $here "smoke-test.ps1") -BaseUrl $candUrl -ExpectedSha $meta.shortSha -ExpectedEnvironment $ExpectedEnvironment -MaxP95Ms $PreTrafficMaxP95Ms -OutputPath (Join-Path $outDir "smoke-candidate-production.json")
if ($LASTEXITCODE -ne 0) {
  Deactivate-Revision $new
  Finish "aborted_before_traffic" 1 "The candidate failed the pre-traffic smoke test. No user traffic was ever sent to it. Production still serves $old at 100%."
}

# ---------------------------------------------------------------- 5. canary steps
$stepNumber = 0
foreach ($weight in $stepList) {
  $stepNumber++
  Write-Host ""
  Write-Host "=== Step $stepNumber of $($stepList.Count): $weight% of the traffic to the candidate ==="

  if ($weight -ge 100) {
    $weights = @("$new=100")
  } else {
    $oldShare = 100 - $weight
    $weights = @("$old=$oldShare", "$new=$weight")
  }
  az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight $weights --output none
  if ($LASTEXITCODE -ne 0) {
    $restored = Restore-Traffic
    Finish "rolled_back" 1 "Could not change the traffic split at step $stepNumber. Traffic restored to $old (confirmed: $restored)."
  }

  Start-Sleep -Seconds 10
  # Wake both revisions up so cold starts do not look like latency problems.
  for ($w = 1; $w -le 4; $w++) { $null = Invoke-Probe "$mainUrl/" }

  $mainResults = @()
  $candResults = @()
  $delayMs = [int](($ObserveSeconds * 1000) / [math]::Max(1, $ProbesPerStep))
  for ($i = 1; $i -le $ProbesPerStep; $i++) {
    $mainResults += Invoke-Probe "$mainUrl/"
    $candResults += Invoke-Probe "$candUrl/"
    Start-Sleep -Milliseconds $delayMs
  }

  $mainErrors = @($mainResults | Where-Object { -not $_.Ok }).Count
  $candErrors = @($candResults | Where-Object { -not $_.Ok }).Count
  $mainErrorPercent = [math]::Round(100.0 * $mainErrors / $mainResults.Count, 1)
  $candErrorPercent = [math]::Round(100.0 * $candErrors / $candResults.Count, 1)
  $mainP95 = Get-P95 ($mainResults | ForEach-Object { $_.Ms })
  $candP95 = Get-P95 ($candResults | ForEach-Object { $_.Ms })

  $served = ($mainResults | Where-Object { $_.Ok } | Group-Object { if ($_.Revision) { $_.Revision } else { "(no revision field)" } } | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }) -join ", "

  Write-Host ("Live URL:  {0} probes, {1} errors ({2}%), p95 {3} ms" -f $mainResults.Count, $mainErrors, $mainErrorPercent, $mainP95)
  Write-Host ("Candidate: {0} probes, {1} errors ({2}%), p95 {3} ms" -f $candResults.Count, $candErrors, $candErrorPercent, $candP95)
  Write-Host "Responses served by: $served"

  $breaches = @()
  if ($mainErrorPercent -gt $MaxErrorRatePercent) { $breaches += "live URL error rate $mainErrorPercent% is above the limit of $MaxErrorRatePercent%" }
  if ($candErrorPercent -gt $MaxErrorRatePercent) { $breaches += "candidate error rate $candErrorPercent% is above the limit of $MaxErrorRatePercent%" }
  if ($mainP95 -gt $CanaryMaxP95Ms) { $breaches += "live URL p95 latency $mainP95 ms is above the limit of $CanaryMaxP95Ms ms" }
  if ($candP95 -gt $CanaryMaxP95Ms) { $breaches += "candidate p95 latency $candP95 ms is above the limit of $CanaryMaxP95Ms ms" }

  $resultText = "pass"
  if ($breaches.Count -gt 0) { $resultText = "fail" }
  $stepResults += [ordered]@{
    step                     = $stepNumber
    trafficToCandidatePercent = $weight
    liveProbes               = $mainResults.Count
    liveErrorPercent         = $mainErrorPercent
    liveP95Ms                = $mainP95
    candidateProbes          = $candResults.Count
    candidateErrorPercent    = $candErrorPercent
    candidateP95Ms           = $candP95
    servedBy                 = $served
    result                   = $resultText
    breaches                 = $breaches
  }

  if ($breaches.Count -gt 0) {
    $reasonText = $breaches -join "; "
    Write-Host "##vso[task.logissue type=warning]Canary step $stepNumber FAILED: $reasonText"
    $restored = Restore-Traffic
    if (-not $restored) {
      Finish "rollback_failed" 1 "CRITICAL: the canary failed ($reasonText) and the automatic rollback could not be confirmed. Run the deployflow-rollback pipeline NOW. Known-good revision: $old"
    }

    Write-Host "Checking that production is healthy again..."
    & (Join-Path $here "smoke-test.ps1") -BaseUrl $mainUrl -ExpectedSha "" -ExpectedEnvironment $ExpectedEnvironment -MaxP95Ms 5000 -OutputPath (Join-Path $outDir "smoke-after-rollback.json")
    if ($LASTEXITCODE -ne 0) {
      Finish "rollback_failed" 1 "CRITICAL: traffic was restored to $old but production does not look healthy. Investigate immediately. The canary failed because: $reasonText"
    }
    Finish "rolled_back" 1 "Canary step $stepNumber ($weight%) failed: $reasonText. Traffic was automatically restored to the known-good revision $old and the candidate was deactivated."
  }
  Write-Host "Step $stepNumber passed."
}

# ---------------------------------------------------------------- 6. promoted: tidy up
$activeText = (az containerapp revision list --name $AppName --resource-group $ResourceGroup --query "[?properties.active].name" -o json | Out-String)
$activeRevisions = ConvertFrom-Json $activeText
foreach ($revisionName in @($activeRevisions)) {
  if ($revisionName -ne $old -and $revisionName -ne $new) {
    Write-Host "Deactivating old revision $revisionName ..."
    Deactivate-Revision $revisionName
  }
}

$record.finalTraffic = @(Get-Traffic | ForEach-Object { "{0}={1}" -f $_.revisionName, $_.weight })
Finish "promoted" 0 "Release promoted: $new now serves 100% of production traffic. The previous revision $old stays active for a fast rollback."