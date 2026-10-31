
# DeployFlow progressive production deployment.
# Uses reusable HTTP connections, paired endpoint measurements,
# baseline-aware latency gates, and independent live latency confirmation.

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
    [string]$ForceRedeploy = "false",
    [int]$WarmupSeconds = 120,
    [int]$BaselineAttempts = 3
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$force = ($ForceRedeploy -eq "true")

# ------------------------------------------------------------
# SHARED HTTP CLIENT
# ------------------------------------------------------------

Add-Type -AssemblyName System.Net.Http

$httpHandler = New-Object System.Net.Http.HttpClientHandler
$script:DeployFlowHttpClient = New-Object System.Net.Http.HttpClient($httpHandler)
$script:DeployFlowHttpClient.Timeout = [TimeSpan]::FromSeconds(10)

# ------------------------------------------------------------
# COMMON FUNCTIONS
# ------------------------------------------------------------

function Fail($message) {
    Write-Host "##vso[task.logissue type=error]$message"
    exit 1
}

function Invoke-Probe($url) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    $revision = $null
    $errorText = ""
    $response = $null

    try {
        $response = $script:DeployFlowHttpClient.GetAsync($url).GetAwaiter().GetResult()

        if ([int]$response.StatusCode -eq 200) {
            $ok = $true

            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

            try {
                $revision = ($content | ConvertFrom-Json).revision
            }
            catch {
                # Root endpoint may return HTML.
                # Revision attribution is informational only.
            }
        }
        else {
            $errorText = "HTTP $([int]$response.StatusCode)"
        }
    }
    catch {
        $errorText = $_.Exception.Message
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }

    $watch.Stop()

    return [pscustomobject]@{
        Ok       = $ok
        Ms       = [int]$watch.ElapsedMilliseconds
        Revision = $revision
        Error    = $errorText
    }
}

function Get-P95($values) {
    $sorted = @($values | Sort-Object)

    if ($sorted.Count -eq 0) {
        return 0
    }

    $index = [math]::Ceiling(0.95 * $sorted.Count) - 1

    return [int]$sorted[$index]
}

function Convert-ProbeResults($results) {
    $errors = @($results | Where-Object { -not $_.Ok }).Count

    $errorPercent = [math]::Round(
        100.0 * $errors / $results.Count,
        1
    )

    $p95 = Get-P95 (
        $results |
        Where-Object { $_.Ok } |
        ForEach-Object { $_.Ms }
    )

    return [pscustomobject]@{
        Results      = $results
        Errors       = $errors
        ErrorPercent = $errorPercent
        P95          = $p95
        Count        = $results.Count
    }
}

function Measure-Endpoint($url, $count) {
    $results = @()

    for ($i = 1; $i -le $count; $i++) {
        $results += Invoke-Probe $url
        Start-Sleep -Milliseconds 250
    }

    return Convert-ProbeResults $results
}

function Measure-PairedEndpoints($mainUrl, $candidateUrl, $count) {
    $mainResults = @()
    $candidateResults = @()

    for ($i = 1; $i -le $count; $i++) {
        # Alternate which endpoint is measured first to reduce
        # systematic timing bias between the two batches.
        if (($i % 2) -eq 1) {
            $mainResults += Invoke-Probe $mainUrl
            $candidateResults += Invoke-Probe $candidateUrl
        }
        else {
            $candidateResults += Invoke-Probe $candidateUrl
            $mainResults += Invoke-Probe $mainUrl
        }

        Start-Sleep -Milliseconds 250
    }

    return [pscustomobject]@{
        Main      = Convert-ProbeResults $mainResults
        Candidate = Convert-ProbeResults $candidateResults
    }
}

function Get-Traffic {
    $text = & az containerapp ingress traffic show `
        --name $AppName `
        --resource-group $ResourceGroup `
        -o json

    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    try {
        return @($text | Out-String | ConvertFrom-Json)
    }
    catch {
        return @()
    }
}

function Deactivate-Revision($name) {
    if ([string]::IsNullOrWhiteSpace($name)) {
        return
    }

    & az containerapp revision deactivate `
        --name $AppName `
        --resource-group $ResourceGroup `
        --revision $name `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "##vso[task.logissue type=warning]Could not deactivate revision $name."
    }
}

function Finish($outcome, $exitCode, $message) {
    $record.outcome = $outcome
    $record.message = $message
    $record.steps = $stepResults

    $record.finishedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $trafficNow = Get-Traffic

    if ($trafficNow.Count -gt 0) {
        $record.finalTraffic = @(
            $trafficNow | ForEach-Object {
                "$($_.revisionName)=$($_.weight)"
            }
        )
    }

    [System.IO.File]::WriteAllText(
        $OutputPath,
        ($record | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding $false)
    )

    Write-Host "##vso[task.setvariable variable=promotionReady]true"

    Write-Host ""
    Write-Host "========================================"
    Write-Host "DEPLOYMENT OUTCOME: $outcome"
    Write-Host "========================================"

    if ($exitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error]$message"
    }
    else {
        Write-Host $message
    }

    $script:DeployFlowHttpClient.Dispose()
    $httpHandler.Dispose()

    exit $exitCode
}

function Restore-Traffic {
    Write-Host "Restoring 100% traffic to known-good revision $old."

    & az containerapp ingress traffic set `
        --name $AppName `
        --resource-group $ResourceGroup `
        --revision-weight "$old=100" `
        --output none

    $restoreOk = ($LASTEXITCODE -eq 0)

    if ($restoreOk) {
        Deactivate-Revision $new
    }

    $check = Get-Traffic | Where-Object {
        $_.revisionName -eq $old -and [int]$_.weight -eq 100
    }

    return ($restoreOk -and [bool]$check)
}

# Wakes a scaled-to-zero app and waits for three consecutive successful probes.
function Wait-ForWarm($url, $maxSeconds) {
    $deadline = (Get-Date).AddSeconds($maxSeconds)
    $streak = 0

    while ((Get-Date) -lt $deadline) {
        $probe = Invoke-Probe $url

        if ($probe.Ok) {
            $streak++

            if ($streak -ge 3) {
                return $true
            }

            Start-Sleep -Milliseconds 500
        }
        else {
            $streak = 0

            Write-Host "Warm-up probe failed: $($probe.Error)"

            Start-Sleep -Seconds 3
        }
    }

    return $false
}

# ------------------------------------------------------------
# 1. VALIDATE PARAMETERS
# ------------------------------------------------------------

if ($ProbesPerStep -lt 1) {
    Fail "ProbesPerStep must be at least 1."
}

if ($ObserveSeconds -lt 1) {
    Fail "ObserveSeconds must be at least 1."
}

if ($WarmupSeconds -lt 1) {
    Fail "WarmupSeconds must be at least 1."
}

if ($BaselineAttempts -lt 1) {
    Fail "BaselineAttempts must be at least 1."
}

if ($MaxErrorRatePercent -lt 0 -or $MaxErrorRatePercent -gt 100) {
    Fail "MaxErrorRatePercent must be between 0 and 100."
}

if ($InjectFaultPercent -lt 0 -or $InjectFaultPercent -gt 100) {
    Fail "InjectFaultPercent must be between 0 and 100."
}

if ($MaxLatencyIncreasePercent -lt 0) {
    Fail "MaxLatencyIncreasePercent cannot be negative."
}

if ($PreTrafficMaxP95Ms -lt 1 -or $CanaryMaxP95Ms -lt 1) {
    Fail "Latency limits must be greater than zero."
}

try {
    $stepList = @(
        $Steps.Split(",") | ForEach-Object {
            [int]$_.Trim()
        }
    )
}
catch {
    Fail "Invalid Steps value. Example: 10,50,100"
}

if ($stepList.Count -eq 0) {
    Fail "At least one traffic step is required."
}

if ($stepList[-1] -ne 100) {
    Fail "The final traffic step must be 100."
}

$previousWeight = 0

foreach ($weight in $stepList) {
    if ($weight -lt 1 -or $weight -gt 100) {
        Fail "Traffic steps must be between 1 and 100."
    }

    if ($weight -le $previousWeight) {
        Fail "Traffic steps must be in strictly increasing order."
    }

    $previousWeight = $weight
}

Write-Host "Traffic rollout steps: $($stepList -join ', ')"
Write-Host "Observation period: $ObserveSeconds seconds"
Write-Host "Probes per step: $ProbesPerStep"
Write-Host "HTTP connection reuse enabled."
Write-Host "Candidate latency gate uses the production baseline."

# ------------------------------------------------------------
# 2. VALIDATE RELEASE METADATA
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $MetadataPath)) {
    Fail "release-metadata.json not found: $MetadataPath"
}

try {
    $meta = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Could not parse release-metadata.json."
}

if ($meta.security.gateResult -ne "passed") {
    Fail "Security gate did not pass."
}

if ($meta.branch -ne "main") {
    Fail "Only main branch images can be deployed."
}

$imageRef = [string]$meta.imageReference

if ($imageRef -notmatch '^.+@sha256:[a-fA-F0-9]{64}$') {
    Fail "Release metadata does not contain a valid SHA256 image digest."
}

$digest = $imageRef.Split("@")[1]

if (-not $meta.shortSha -or -not $meta.gitSha) {
    Fail "Release metadata is missing Git commit information."
}

# ------------------------------------------------------------
# 3. VERIFY STAGING PROMOTION
# ------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($RequiredRecordPath)) {
    if (-not (Test-Path -LiteralPath $RequiredRecordPath)) {
        Fail "Staging promotion record not found: $RequiredRecordPath"
    }

    try {
        $required = Get-Content -LiteralPath $RequiredRecordPath -Raw | ConvertFrom-Json
    }
    catch {
        Fail "Could not parse staging promotion record."
    }

    if ($required.imageReference -ne $imageRef) {
        Fail "Staging and production image digests do not match."
    }

    if ($required.outcome -and $required.outcome -notin @("promoted", "already_live")) {
        Fail "Staging did not successfully promote this image. Outcome: $($required.outcome)"
    }

    Write-Host "Staging digest verification passed."
}

# ------------------------------------------------------------
# 4. VERIFY IMAGE IN ACR
# ------------------------------------------------------------

$registryHost = $imageRef.Split("/")[0]
$registryName = $registryHost.Split(".")[0]
$repoAndDigest = $imageRef.Substring($registryHost.Length + 1)

$verifiedDigest = & az acr repository show `
    --name $registryName `
    --image $repoAndDigest `
    --query digest `
    -o tsv

if ($LASTEXITCODE -ne 0) {
    Fail "Image was not found in ACR."
}

$verifiedDigest = ([string]$verifiedDigest).Trim()

if ($verifiedDigest -ne $digest) {
    Fail "ACR digest verification failed. Expected $digest but received $verifiedDigest."
}

Write-Host "ACR image digest verified: $verifiedDigest"

# ------------------------------------------------------------
# 5. PREPARE OUTPUT AND PROMOTION RECORD
# ------------------------------------------------------------

$outDir = Split-Path -Parent $OutputPath

if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outDir = (Get-Location).Path
    $OutputPath = Join-Path $outDir (Split-Path -Leaf $OutputPath)
}

if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$stepResults = @()

$record = [ordered]@{
    environment                    = $EnvironmentName
    appName                        = $AppName
    resourceGroup                  = $ResourceGroup
    imageReference                 = $imageRef
    imageDigest                    = $digest
    shortSha                       = $meta.shortSha
    gitSha                         = $meta.gitSha
    appVersion                     = $meta.appVersion
    sourceBuildId                  = $meta.buildId
    sourcePipelineRunUrl           = $meta.pipelineRunUrl
    strategy                       = "progressive: $Steps"
    observeSeconds                 = $ObserveSeconds
    probesPerStep                  = $ProbesPerStep
    injectFaultPercent             = $InjectFaultPercent
    forceRedeploy                  = $force
    baselineP95Ms                  = $null
    maxLatencyIncreasePercent      = $MaxLatencyIncreasePercent
    latencyConfirmationEnabled     = $true
    latencyConfirmationDelaySeconds = 10
    measurementMethod              = "shared_http_client_alternating_endpoint_probes"
    candidateLatencyGate           = "baseline_aware"
    outcome                        = "started"
    message                        = ""
    previousRevision               = $null
    previousImage                  = $null
    candidateRevision              = $null
    steps                          = @()
    finalTraffic                   = @()
    startedAtUtc                   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    finishedAtUtc                  = $null
    deploymentRunUrl               = $RunUrl
}

# ------------------------------------------------------------
# 6. IDENTIFY CURRENT PRODUCTION REVISION
# ------------------------------------------------------------

$stateText = & az containerapp show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --query "{latest:properties.latestRevisionName,traffic:properties.configuration.ingress.traffic,fqdn:properties.configuration.ingress.fqdn}" `
    -o json

if ($LASTEXITCODE -ne 0) {
    Fail "Could not read production Container App."
}

try {
    $state = $stateText | Out-String | ConvertFrom-Json
}
catch {
    Fail "Could not parse production Container App state."
}

if ([string]::IsNullOrWhiteSpace($state.fqdn)) {
    Fail "Production Container App ingress FQDN is missing."
}

$mainUrl = "https://$($state.fqdn)"

Write-Host "Production URL: $mainUrl"

Write-Host "##vso[task.setvariable variable=appUrl]$mainUrl"
Write-Host "##vso[task.setvariable variable=shortSha]$($meta.shortSha)"

$full = @($state.traffic) | Where-Object {
    [int]$_.weight -eq 100
} | Select-Object -First 1

if (-not $full) {
    Fail "Production traffic is split. Restore a known-good revision before deploying."
}

$old = [string]$full.revisionName

if ([string]::IsNullOrWhiteSpace($old)) {
    Fail "Could not identify known-good production revision."
}

$oldImage = & az containerapp revision show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --revision $old `
    --query "properties.template.containers[0].image" `
    -o tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($oldImage)) {
    Fail "Could not read known-good revision image."
}

$oldImage = ([string]$oldImage).Trim()

$record.previousRevision = $old
$record.previousImage = $oldImage

Write-Host "Known-good revision: $old"
Write-Host "Known-good image: $oldImage"
Write-Host "Release image: $imageRef"

# ------------------------------------------------------------
# 7. SKIP IF THE IMAGE IS ALREADY LIVE
# ------------------------------------------------------------

if (($oldImage -eq $imageRef) -and (-not $force)) {
    $record.candidateRevision = $old
    Finish "already_live" 0 "This exact image is already live. Nothing to deploy."
}

# ------------------------------------------------------------
# 8. WARM PRODUCTION AND MEASURE BASELINE
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Warming up existing production ==="

if (-not (Wait-ForWarm $mainUrl $WarmupSeconds)) {
    Fail "Production did not respond successfully within $WarmupSeconds seconds. No traffic was changed."
}

Write-Host "Production is warm."

Write-Host ""
Write-Host "=== Measuring existing production baseline ==="

$baseline = $null

for ($attempt = 1; $attempt -le $BaselineAttempts; $attempt++) {
    $baseline = Measure-Endpoint $mainUrl $ProbesPerStep

    Write-Host "Baseline attempt ${attempt}: $($baseline.Count) probes, $($baseline.Errors) errors ($($baseline.ErrorPercent)%)"

    if ($baseline.ErrorPercent -le $MaxErrorRatePercent) {
        break
    }

    foreach ($failedProbe in @(
        $baseline.Results |
        Where-Object { -not $_.Ok } |
        Select-Object -First 3
    )) {
        Write-Host "Failed probe after $($failedProbe.Ms) ms: $($failedProbe.Error)"
    }

    if ($attempt -lt $BaselineAttempts) {
        Write-Host "Baseline error rate is above the configured limit. Waiting 15 seconds."
        Start-Sleep -Seconds 15
    }
}

if ($baseline.ErrorPercent -gt $MaxErrorRatePercent) {
    Fail "Existing production baseline stayed above $MaxErrorRatePercent% errors. Fix production health before starting a canary."
}

$okLatencies = @(
    $baseline.Results |
    Where-Object { $_.Ok } |
    ForEach-Object { $_.Ms }
)

$baselineP95 = Get-P95 $okLatencies

$record.baselineP95Ms = $baselineP95

Write-Host "Production baseline: $($okLatencies.Count) successful probes, p95 $baselineP95 ms"

# ------------------------------------------------------------
# 9. PIN KNOWN-GOOD REVISION TO 100%
# ------------------------------------------------------------

& az containerapp ingress traffic set `
    --name $AppName `
    --resource-group $ResourceGroup `
    --revision-weight "$old=100" `
    --output none

if ($LASTEXITCODE -ne 0) {
    Finish "failed_before_deploy" 1 "Could not pin production traffic to the known-good revision."
}

# ------------------------------------------------------------
# 10. CREATE CANDIDATE REVISION
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Creating candidate revision ==="

& az containerapp update `
    --name $AppName `
    --resource-group $ResourceGroup `
    --image $imageRef `
    --revision-suffix $RevisionSuffix `
    --set-env-vars "FAULT_INJECTION_PERCENT=$InjectFaultPercent" `
    --output none

if ($LASTEXITCODE -ne 0) {
    Finish "failed_before_traffic" 1 "Candidate deployment failed. Production traffic was not shifted."
}

$candText = & az containerapp show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --query "{latest:properties.latestRevisionName,fqdn:properties.latestRevisionFqdn}" `
    -o json

if ($LASTEXITCODE -ne 0) {
    Finish "failed_before_traffic" 1 "Could not identify candidate revision."
}

try {
    $cand = $candText | Out-String | ConvertFrom-Json
}
catch {
    Finish "failed_before_traffic" 1 "Could not parse candidate revision information."
}

$new = [string]$cand.latest

$record.candidateRevision = $new

if (
    [string]::IsNullOrWhiteSpace($new) -or
    $new -eq $old -or
    [string]::IsNullOrWhiteSpace($cand.fqdn)
) {
    Finish "failed_before_traffic" 1 "Candidate revision could not be identified."
}

$candUrl = "https://$($cand.fqdn)"

Write-Host "Candidate revision: $new"
Write-Host "Candidate URL: $candUrl"

# ------------------------------------------------------------
# 11. CANDIDATE PRE-TRAFFIC SMOKE TEST
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Candidate pre-traffic smoke test ==="

& (Join-Path $here "smoke-test.ps1") `
    -BaseUrl $candUrl `
    -ExpectedSha $meta.shortSha `
    -ExpectedEnvironment $ExpectedEnvironment `
    -MaxP95Ms $PreTrafficMaxP95Ms `
    -OutputPath (Join-Path $outDir "smoke-candidate-production.json")
$smokeSucceeded = $?

if (-not $smokeSucceeded) {
    Deactivate-Revision $new

    Finish `
        "aborted_before_traffic" `
        1 `
        "Candidate failed pre-traffic smoke test. Production remains on the known-good revision."
}

Write-Host "Candidate pre-traffic smoke test passed."

# ------------------------------------------------------------
# 12. PROGRESSIVE TRAFFIC ROLLOUT
# ------------------------------------------------------------

$stepNumber = 0

foreach ($weight in $stepList) {
    $stepNumber++

    Write-Host ""
    Write-Host "========================================"
    Write-Host "STEP $stepNumber OF $($stepList.Count): $weight% CANDIDATE TRAFFIC"
    Write-Host "========================================"

    if ($weight -ge 100) {
        $weights = @("$new=100")
    }
    else {
        $oldWeight = [int](100 - $weight)

        $weights = @(
            "$old=$oldWeight",
            "$new=$weight"
        )
    }

    & az containerapp ingress traffic set `
        --name $AppName `
        --resource-group $ResourceGroup `
        --revision-weight $weights `
        --output none

    if ($LASTEXITCODE -ne 0) {
        $restored = Restore-Traffic

        if (-not $restored) {
            Finish "rollback_failed" 1 "Traffic shift failed and rollback could not be confirmed. Manual recovery is required."
        }

        Finish "rolled_back" 1 "Traffic shift failed. Traffic restored to $old."
    }

    Write-Host "Traffic shifted. Observing for $ObserveSeconds seconds."

    Start-Sleep -Seconds $ObserveSeconds

    # Warm both endpoints before measuring.
    for ($w = 1; $w -le 4; $w++) {
        $null = Invoke-Probe "$mainUrl/"
        $null = Invoke-Probe "$candUrl/"
    }

    # Alternate live and candidate probes to reduce measurement-order bias.
    $paired = Measure-PairedEndpoints $mainUrl $candUrl $ProbesPerStep

    $main = $paired.Main
    $candidate = $paired.Candidate

    $mainP95 = $main.P95
    $candP95 = $candidate.P95

    $mainErrorPercent = $main.ErrorPercent
    $candErrorPercent = $candidate.ErrorPercent

    $allowedBaselineP95 = [math]::Ceiling(
        $baselineP95 * (1 + ($MaxLatencyIncreasePercent / 100.0))
    )

    $effectiveLiveLimit = [math]::Min(
        $CanaryMaxP95Ms,
        $allowedBaselineP95
    )

    Write-Host "Baseline p95: $baselineP95 ms"
    Write-Host "Effective live and candidate p95 limit: $effectiveLiveLimit ms"

    Write-Host "Live endpoint: $($main.Count) probes, $($main.Errors) errors ($mainErrorPercent%), p95 $mainP95 ms"

    Write-Host "Candidate endpoint: $($candidate.Count) probes, $($candidate.Errors) errors ($candErrorPercent%), p95 $candP95 ms"

    # --------------------------------------------------------
    # LATENCY CONFIRMATION AND ROLLOUT GATES
    # --------------------------------------------------------

    $breaches = @()

    $mainLatencyConfirmationP95 = $null
    $mainLatencyConfirmationErrors = $null
    $mainLatencyConfirmationResult = "not_needed"

    # Error-rate breaches remain immediate failures.
    if ($mainErrorPercent -gt $MaxErrorRatePercent) {
        $breaches += "Live error rate $mainErrorPercent% exceeds $MaxErrorRatePercent%."
    }

    if ($candErrorPercent -gt $MaxErrorRatePercent) {
        $breaches += "Candidate error rate $candErrorPercent% exceeds $MaxErrorRatePercent%."
    }

    # Confirm a live latency breach using a separate probe batch.
    if ($mainP95 -gt $effectiveLiveLimit) {
        if ($mainErrorPercent -gt $MaxErrorRatePercent) {
            $mainLatencyConfirmationResult = "skipped_live_errors"

            $breaches += "Live latency exceeded its limit and the live error rate also breached its limit."
        }
        else {
            Write-Host ""
            Write-Host "WARNING: Live p95 exceeded its limit."
            Write-Host "Waiting 10 seconds before independent confirmation."

            Start-Sleep -Seconds 10

            $confirmation = Measure-Endpoint $mainUrl $ProbesPerStep

            $mainLatencyConfirmationP95 = $confirmation.P95
            $mainLatencyConfirmationErrors = $confirmation.ErrorPercent

            Write-Host "Latency confirmation: $($confirmation.Count) probes, $($confirmation.Errors) errors ($($confirmation.ErrorPercent)%), p95 $($confirmation.P95) ms"

            if ($confirmation.ErrorPercent -gt $MaxErrorRatePercent) {
                $mainLatencyConfirmationResult = "failed_errors"

                $breaches += "Latency confirmation error rate $($confirmation.ErrorPercent)% exceeds $MaxErrorRatePercent%."
            }
            elseif ($confirmation.P95 -gt $effectiveLiveLimit) {
                $mainLatencyConfirmationResult = "confirmed_breach"

                $breaches += "Live p95 breach confirmed: first batch $mainP95 ms and confirmation $($confirmation.P95) ms both exceed $effectiveLiveLimit ms."
            }
            else {
                $mainLatencyConfirmationResult = "passed"

                Write-Host "Latency confirmation passed. Treating the first high-p95 measurement as a transient spike."
            }
        }
    }

    # Candidate latency breaches are immediate and use the same baseline-aware limit.
    if ($candP95 -gt $effectiveLiveLimit) {
        $breaches += "Candidate p95 $candP95 ms exceeds baseline-aware limit $effectiveLiveLimit ms."
    }

    $resultText = "pass"

    if ($breaches.Count -gt 0) {
        $resultText = "fail"
    }

    $stepResults += [ordered]@{
        step                          = $stepNumber
        trafficToCandidatePercent     = $weight
        baselineP95Ms                 = $baselineP95
        effectiveLiveLimitMs          = $effectiveLiveLimit
        effectiveCandidateLimitMs     = $effectiveLiveLimit
        liveProbes                    = $main.Count
        liveErrorPercent              = $mainErrorPercent
        liveP95Ms                     = $mainP95
        mainLatencyConfirmationP95Ms  = $mainLatencyConfirmationP95
        mainLatencyConfirmationErrors = $mainLatencyConfirmationErrors
        mainLatencyConfirmationResult = $mainLatencyConfirmationResult
        candidateProbes               = $candidate.Count
        candidateErrorPercent         = $candErrorPercent
        candidateP95Ms                = $candP95
        result                        = $resultText
        breaches                      = $breaches
    }

    if ($breaches.Count -gt 0) {
        $reasonText = $breaches -join "; "

        Write-Host "##vso[task.logissue type=warning]Canary step $stepNumber FAILED: $reasonText"

        $restored = Restore-Traffic

        if (-not $restored) {
            Finish "rollback_failed" 1 "CRITICAL: rollback could not be confirmed. Run the rollback pipeline."
        }

        Write-Host "Checking production after rollback..."

        & (Join-Path $here "smoke-test.ps1") `
            -BaseUrl $mainUrl `
            -ExpectedSha "" `
            -ExpectedEnvironment $ExpectedEnvironment `
            -MaxP95Ms 5000 `
            -OutputPath (Join-Path $outDir "smoke-after-rollback.json")

        $rollbackSmokeSucceeded = $?

        if (-not $rollbackSmokeSucceeded) {
            Finish "rollback_failed" 1 "Traffic restored but production health verification failed."
        }

        Finish `
            "rolled_back" `
            1 `
            "Canary step $stepNumber failed: $reasonText. Traffic restored to $old."
    }

    Write-Host "Step $stepNumber passed."
}

# ------------------------------------------------------------
# 13. VERIFY FINAL TRAFFIC AND KEEP OLD REVISION ACTIVE
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Verifying final production traffic ==="

$finalTraffic = Get-Traffic

$finalCandidate = @(
    $finalTraffic | Where-Object {
        $_.revisionName -eq $new -and [int]$_.weight -eq 100
    }
)

if (-not $finalCandidate) {
    Finish "verification_failed" 1 "Candidate did not receive 100% production traffic."
}

$finalOld = @(
    $finalTraffic | Where-Object {
        $_.revisionName -eq $old
    }
)

if ($finalOld.Count -eq 0) {
    Write-Host "Previous revision is no longer in the traffic list."
}
else {
    Write-Host "Previous revision remains configured for rollback."
}

# Confirm the candidate image is still the expected digest.
$finalImage = & az containerapp revision show `
    --name $AppName `
    --resource-group $ResourceGroup `
    --revision $new `
    --query "properties.template.containers[0].image" `
    -o tsv

if ($LASTEXITCODE -ne 0 -or ([string]$finalImage).Trim() -ne $imageRef) {
    Finish "verification_failed" 1 "Final candidate image verification failed."
}

# ------------------------------------------------------------
# 14. CLEAN UP OTHER ACTIVE REVISIONS
# ------------------------------------------------------------

$activeText = & az containerapp revision list `
    --name $AppName `
    --resource-group $ResourceGroup `
    --query "[?properties.active].name" `
    -o json

if ($LASTEXITCODE -ne 0) {
    Finish "promoted_with_cleanup_warning" 1 "Release completed but could not inspect active revisions."
}

try {
    $activeRevisions = $activeText | Out-String | ConvertFrom-Json
}
catch {
    Finish "promoted_with_cleanup_warning" 1 "Release completed but active revision list could not be parsed."
}

foreach ($revisionName in @($activeRevisions)) {
    if ($revisionName -ne $old -and $revisionName -ne $new) {
        Deactivate-Revision $revisionName
    }
}

# ------------------------------------------------------------
# 15. FINAL PROMOTION RECORD
# ------------------------------------------------------------

$record.finalTraffic = @(
    Get-Traffic | ForEach-Object {
        "$($_.revisionName)=$($_.weight)"
    }
)

Finish `
    "promoted" `
    0 `
    "Release promoted successfully: $new now serves 100% of production traffic. Previous revision $old remains active for rollback."
