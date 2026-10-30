
# DeployFlow progressive production deployment with baseline-aware canary checks.
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
  [double]$MaxLatencyIncreasePercent = 50,
  [int]$InjectFaultPercent = 0,
  [string]$ForceRedeploy = "false"
)

$here = $PSScriptRoot
$force = ($ForceRedeploy -eq "true")

function Fail($message) {
  Write-Host "##vso[task.logissue type=error]$message"
  exit 1
}

function Invoke-Probe($url) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $ok = $false
  $revision = $null

  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200) {
      $ok = $true
      try {
        $revision = ($response.Content | ConvertFrom-Json).revision
      } catch {}
    }
  } catch {}

  $watch.Stop()

  [pscustomobject]@{
    Ok = $ok
    Ms = [int]$watch.ElapsedMilliseconds
    Revision = $revision
  }
}

function Get-P95($values) {
  $sorted = @($values | Sort-Object)
  if ($sorted.Count -eq 0) { return 0 }
  $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
  return [int]$sorted[$index]
}

function Get-Traffic {
  $text = az containerapp ingress traffic show --name $AppName --resource-group $ResourceGroup -o json | Out-String
  if ($LASTEXITCODE -ne 0) { return @() }
  return @(ConvertFrom-Json $text)
}

function Deactivate-Revision($name) {
  az containerapp revision deactivate --name $AppName --resource-group $ResourceGroup --revision $name --output none
  if ($LASTEXITCODE -ne 0) {
    Write-Host "##vso[task.logissue type=warning]Could not deactivate revision $name"
  }
}

function Finish($outcome, $exitCode, $message) {
  $record.outcome = $outcome
  $record.message = $message
  $record.steps = $stepResults
  $record.finishedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

  [System.IO.File]::WriteAllText(
    $OutputPath,
    ($record | ConvertTo-Json -Depth 8),
    (New-Object System.Text.UTF8Encoding $false)
  )

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
  Write-Host "Restoring 100% of traffic to known-good revision $old ..."

  az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight "$old=100" --output none
  $restoreOk = ($LASTEXITCODE -eq 0)

  if ($restoreOk) {
    Deactivate-Revision $new
  }

  $check = Get-Traffic | Where-Object {
    $_.revisionName -eq $old -and $_.weight -eq 100
  }

  return ($restoreOk -and [bool]$check)
}

function Measure-Endpoint($url, $count) {
  $results = @()

  for ($i = 1; $i -le $count; $i++) {
    $results += Invoke-Probe $url
    Start-Sleep -Milliseconds 250
  }

  $errors = @($results | Where-Object { -not $_.Ok }).Count
  $errorPercent = [math]::Round(100.0 * $errors / $results.Count, 1)
  $p95 = Get-P95 ($results | ForEach-Object { $_.Ms })

  return [pscustomobject]@{
    Results = $results
    Errors = $errors
    ErrorPercent = $errorPercent
    P95 = $p95
    Count = $results.Count
  }
}

# 1. Validate release metadata and staging digest.
if (-not (Test-Path $MetadataPath)) {
  Fail "release-metadata.json not found: $MetadataPath"
}

$meta = Get-Content $MetadataPath -Raw | ConvertFrom-Json

if ($meta.security.gateResult -ne "passed") {
  Fail "Security gate did not pass."
}

if ($meta.branch -ne "main") {
  Fail "Only main branch images can be deployed."
}

$imageRef = $meta.imageReference

if (-not $imageRef -or $imageRef -notmatch "@sha256:") {
  Fail "Release metadata has no image digest."
}

$digest = $imageRef.Split("@")[1]

if ($RequiredRecordPath) {
  if (-not (Test-Path $RequiredRecordPath)) {
    Fail "Staging promotion record not found."
  }

  $required = Get-Content $RequiredRecordPath -Raw | ConvertFrom-Json

  if ($required.imageReference -ne $imageRef) {
    Fail "Staging and production image digests do not match."
  }

  Write-Host "Digest matches the one verified in staging."
}

$stepList = @($Steps.Split(",") | ForEach-Object { [int]($_.Trim()) })

if ($stepList.Count -eq 0 -or $stepList[-1] -ne 100) {
  Fail "Steps must end with 100."
}

if ($MaxLatencyIncreasePercent -lt 0) {
  Fail "MaxLatencyIncreasePercent cannot be negative."
}

$registryHost = $imageRef.Split("/")[0]
$registryName = $registryHost.Split(".")[0]
$repoAndDigest = $imageRef.Substring($registryHost.Length + 1)

az acr repository show --name $registryName --image $repoAndDigest --query digest -o tsv | Out-Null

if ($LASTEXITCODE -ne 0) {
  Fail "Image was not found in ACR."
}

$outDir = Split-Path -Parent $OutputPath

if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$stepResults = @()

$record = [ordered]@{
  environment = $EnvironmentName
  appName = $AppName
  resourceGroup = $ResourceGroup
  imageReference = $imageRef
  imageDigest = $digest
  shortSha = $meta.shortSha
  gitSha = $meta.gitSha
  appVersion = $meta.appVersion
  sourceBuildId = $meta.buildId
  sourcePipelineRunUrl = $meta.pipelineRunUrl
  strategy = "progressive: $Steps"
  injectFaultPercent = $InjectFaultPercent
  forceRedeploy = $force
  baselineP95Ms = $null
  maxLatencyIncreasePercent = $MaxLatencyIncreasePercent
  outcome = "started"
  message = ""
  previousRevision = $null
  previousImage = $null
  candidateRevision = $null
  steps = @()
  finalTraffic = $null
  startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  finishedAtUtc = $null
  deploymentRunUrl = $RunUrl
}

# 2. Identify the current production revision.
$stateText = az containerapp show --name $AppName --resource-group $ResourceGroup --query "{latest:properties.latestRevisionName,traffic:properties.configuration.ingress.traffic,fqdn:properties.configuration.ingress.fqdn}" -o json | Out-String

if ($LASTEXITCODE -ne 0) {
  Fail "Could not read production Container App."
}

$state = ConvertFrom-Json $stateText
$mainUrl = "https://" + $state.fqdn

Write-Host "##vso[task.setvariable variable=appUrl]$mainUrl"
Write-Host "##vso[task.setvariable variable=shortSha]$($meta.shortSha)"

$full = @($state.traffic) | Where-Object { $_.weight -eq 100 } | Select-Object -First 1

if (-not $full) {
  Fail "Production traffic is split. Restore a known-good revision before deploying."
}

$old = $state.latest
if ($full.revisionName) { $old = $full.revisionName }

$oldImage = (az containerapp revision show --name $AppName --resource-group $ResourceGroup --revision $old --query "properties.template.containers[0].image" -o tsv | Out-String).Trim()

if ($LASTEXITCODE -ne 0 -or -not $oldImage) {
  Fail "Could not read known-good revision image."
}

$record.previousRevision = $old
$record.previousImage = $oldImage

Write-Host "Known-good revision: $old"
Write-Host "Known-good image: $oldImage"
Write-Host "Release image: $imageRef"

if (($oldImage -eq $imageRef) -and (-not $force)) {
  $record.candidateRevision = $old
  Finish "already_live" 0 "This image is already live. Nothing to deploy."
}

# 3. Measure the existing production baseline BEFORE changing traffic.
Write-Host ""
Write-Host "=== Measuring existing production baseline ==="

$baseline = Measure-Endpoint $mainUrl $ProbesPerStep

if ($baseline.Errors -gt 0) {
  Fail "Existing production baseline has $($baseline.Errors) failed probes. Fix production health before starting a canary."
}

$baselineP95 = $baseline.P95
$record.baselineP95Ms = $baselineP95

Write-Host "Production baseline: $($baseline.Count) probes, p95 $baselineP95 ms"

# 4. Keep the known-good revision at 100%, then create candidate.
az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight "$old=100" --output none

if ($LASTEXITCODE -ne 0) {
  Finish "failed_before_deploy" 1 "Could not pin production traffic."
}

Write-Host "Creating candidate from the verified image digest..."

az containerapp update --name $AppName --resource-group $ResourceGroup --image $imageRef --revision-suffix $RevisionSuffix --set-env-vars "FAULT_INJECTION_PERCENT=$InjectFaultPercent" --output none

if ($LASTEXITCODE -ne 0) {
  Finish "failed_before_traffic" 1 "Candidate deployment failed. Production traffic was not shifted."
}

$candText = az containerapp show --name $AppName --resource-group $ResourceGroup --query "{latest:properties.latestRevisionName,fqdn:properties.latestRevisionFqdn}" -o json | Out-String

if ($LASTEXITCODE -ne 0) {
  Finish "failed_before_traffic" 1 "Could not identify candidate revision."
}

$cand = ConvertFrom-Json $candText
$new = $cand.latest
$record.candidateRevision = $new

if (-not $new -or $new -eq $old -or -not $cand.fqdn) {
  Finish "failed_before_traffic" 1 "Candidate revision could not be identified."
}

$candUrl = "https://" + $cand.fqdn

Write-Host "Candidate revision: $new"
Write-Host "Candidate URL: $candUrl (0% traffic)"

# 5. Candidate pre-traffic smoke test.
& (Join-Path $here "smoke-test.ps1") -BaseUrl $candUrl -ExpectedSha $meta.shortSha -ExpectedEnvironment $ExpectedEnvironment -MaxP95Ms $PreTrafficMaxP95Ms -OutputPath (Join-Path $outDir "smoke-candidate-production.json")

if ($LASTEXITCODE -ne 0) {
  Deactivate-Revision $new
  Finish "aborted_before_traffic" 1 "Candidate failed pre-traffic smoke test. Production remains on the known-good revision."
}

# 6. Progressive traffic rollout.
$stepNumber = 0

foreach ($weight in $stepList) {
  $stepNumber++

  Write-Host ""
  Write-Host "=== Step $stepNumber of $($stepList.Count): $weight% candidate traffic ==="

  if ($weight -ge 100) {
    $weights = @("$new=100")
  } else {
    $weights = @("$old=$([int](100 - $weight))", "$new=$weight")
  }

  az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight $weights --output none

  if ($LASTEXITCODE -ne 0) {
    $restored = Restore-Traffic
    Finish "rolled_back" 1 "Traffic shift failed. Rollback confirmed: $restored"
  }

  Start-Sleep -Seconds 10

  # Warm both revisions.
  for ($w = 1; $w -le 4; $w++) {
    $null = Invoke-Probe "$mainUrl/"
    $null = Invoke-Probe "$candUrl/"
  }

  # Measure the public production endpoint and candidate direct endpoint.
  $main = Measure-Endpoint $mainUrl $ProbesPerStep
  $candidate = Measure-Endpoint $candUrl $ProbesPerStep

  $mainP95 = $main.P95
  $candP95 = $candidate.P95

  $mainErrorPercent = $main.ErrorPercent
  $candErrorPercent = $candidate.ErrorPercent

  $allowedBaselineP95 = [math]::Ceiling($baselineP95 * (1 + ($MaxLatencyIncreasePercent / 100.0)))
  $effectiveLiveLimit = [math]::Min($CanaryMaxP95Ms, $allowedBaselineP95)

  Write-Host "Baseline p95: $baselineP95 ms"
  Write-Host "Allowed live p95: $effectiveLiveLimit ms"
  Write-Host "Live URL: $($main.Count) probes, $($main.Errors) errors ($mainErrorPercent%), p95 $mainP95 ms"
  Write-Host "Candidate: $($candidate.Count) probes, $($candidate.Errors) errors ($candErrorPercent%), p95 $candP95 ms"

  $breaches = @()

  if ($mainErrorPercent -gt $MaxErrorRatePercent) {
    $breaches += "Live error rate $mainErrorPercent% exceeds $MaxErrorRatePercent%"
  }

  if ($candErrorPercent -gt $MaxErrorRatePercent) {
    $breaches += "Candidate error rate $candErrorPercent% exceeds $MaxErrorRatePercent%"
  }

  if ($mainP95 -gt $effectiveLiveLimit) {
    $breaches += "Live p95 $mainP95 ms exceeds effective limit $effectiveLiveLimit ms"
  }

  if ($candP95 -gt $CanaryMaxP95Ms) {
    $breaches += "Candidate p95 $candP95 ms exceeds $CanaryMaxP95Ms ms"
  }

  $resultText = "pass"
  if ($breaches.Count -gt 0) { $resultText = "fail" }

  $stepResults += [ordered]@{
    step = $stepNumber
    trafficToCandidatePercent = $weight
    baselineP95Ms = $baselineP95
    effectiveLiveLimitMs = $effectiveLiveLimit
    liveProbes = $main.Count
    liveErrorPercent = $mainErrorPercent
    liveP95Ms = $mainP95
    candidateProbes = $candidate.Count
    candidateErrorPercent = $candErrorPercent
    candidateP95Ms = $candP95
    result = $resultText
    breaches = $breaches
  }

  if ($breaches.Count -gt 0) {
    $reasonText = $breaches -join "; "
    Write-Host "##vso[task.logissue type=warning]Canary step $stepNumber FAILED: $reasonText"

    $restored = Restore-Traffic

    if (-not $restored) {
      Finish "rollback_failed" 1 "CRITICAL: rollback could not be confirmed. Run deployflow-rollback pipeline."
    }

    Write-Host "Checking production after rollback..."

    & (Join-Path $here "smoke-test.ps1") -BaseUrl $mainUrl -ExpectedSha "" -ExpectedEnvironment $ExpectedEnvironment -MaxP95Ms 5000 -OutputPath (Join-Path $outDir "smoke-after-rollback.json")

    if ($LASTEXITCODE -ne 0) {
      Finish "rollback_failed" 1 "Traffic restored but production health verification failed."
    }

    Finish "rolled_back" 1 "Canary step $stepNumber failed: $reasonText. Traffic restored to $old."
  }

  Write-Host "Step $stepNumber passed."
}

# 7. Keep previous revision active for fast rollback.
$activeText = az containerapp revision list --name $AppName --resource-group $ResourceGroup --query "[?properties.active].name" -o json | Out-String

if ($LASTEXITCODE -ne 0) {
  Finish "promoted_with_cleanup_warning" 1 "Release completed but could not inspect active revisions."
}

$activeRevisions = ConvertFrom-Json $activeText

foreach ($revisionName in @($activeRevisions)) {
  if ($revisionName -ne $old -and $revisionName -ne $new) {
    Deactivate-Revision $revisionName
  }
}

$record.finalTraffic = @(Get-Traffic | ForEach-Object { "$($_.revisionName)=$($_.weight)" })

Finish "promoted" 0 "Release promoted: $new now serves 100% of production traffic. Previous revision $old remains active for rollback."
