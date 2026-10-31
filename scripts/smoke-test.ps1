
<#
Smoke test for a deployed DeployFlow app.

Checks:
1. /health reports healthy.
2. /api/info reports the expected environment and commit.
3. Every burst request succeeds and p95 is within the configured limit.

Uses a shared HttpClient to reuse connections.
Exit code 0 = pass, 1 = fail.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [string]$ExpectedSha = "",

    [Parameter(Mandatory = $true)]
    [string]$ExpectedEnvironment,

    [int]$WarmupSeconds = 180,
    [int]$Requests = 20,
    [int]$MaxP95Ms = 1500,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd("/")
$failures = @()
$latencies = @()
$errorCount = 0
$p95 = $null
$reportedSha = $null
$reportedEnvironment = $null
$lastError = ""

Add-Type -AssemblyName System.Net.Http

$handler = New-Object System.Net.Http.HttpClientHandler
$httpClient = New-Object System.Net.Http.HttpClient($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds(10)

function Get-Response($url) {
    $response = $httpClient.GetAsync($url).GetAwaiter().GetResult()

    try {
        $status = [int]$response.StatusCode
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if ($status -ne 200) {
            throw "HTTP $status"
        }

        return $content
    }
    finally {
        $response.Dispose()
    }
}

function Get-Json($url) {
    $content = Get-Response $url
    return ($content | ConvertFrom-Json)
}

function Get-P95($values) {
    $sorted = @($values | Sort-Object)

    if ($sorted.Count -eq 0) {
        return 0
    }

    $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
    return [int]$sorted[$index]
}

try {
    # 1. Wait for the app to become healthy.
    Write-Host "1/3 Waiting for $BaseUrl/health to report healthy (up to $WarmupSeconds seconds)..."

    $healthy = $false
    $deadline = (Get-Date).AddSeconds($WarmupSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $health = Get-Json "$BaseUrl/health"

            if ($health.status -eq "healthy") {
                $healthy = $true
                break
            }

            $lastError = "Health status was '$($health.status)'"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 3
    }

    if (-not $healthy) {
        $failures += "The app never became healthy within $WarmupSeconds seconds. Last error: $lastError"
    }

    # 2. Verify application identity.
    if ($healthy) {
        Write-Host "2/3 Checking /api/info..."

        try {
            $info = Get-Json "$BaseUrl/api/info"

            $reportedSha = $info.gitSha
            $reportedEnvironment = $info.environment

            if ($ExpectedSha -and ($reportedSha -ne $ExpectedSha)) {
                $failures += "Wrong commit: app reports '$reportedSha'; expected '$ExpectedSha'."
            }

            if ($reportedEnvironment -ne $ExpectedEnvironment) {
                $failures += "Wrong environment: app reports '$reportedEnvironment'; expected '$ExpectedEnvironment'."
            }
        }
        catch {
            $failures += "Could not read /api/info: $($_.Exception.Message)"
        }
    }

    # 3. Measure burst latency.
    if ($healthy) {
        Write-Host "3/3 Sending $Requests requests..."

        for ($i = 1; $i -le $Requests; $i++) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $null = Get-Response "$BaseUrl/health"
            }
            catch {
                $errorCount++
                Write-Host "Request $i failed: $($_.Exception.Message)"
            }

            $watch.Stop()
            $latencies += [int]$watch.ElapsedMilliseconds
        }

        $p95 = Get-P95 $latencies

        if ($errorCount -gt 0) {
            $failures += "$errorCount of $Requests requests failed."
        }

        if ($p95 -gt $MaxP95Ms) {
            $failures += "95th percentile latency was $p95 ms, above the limit of $MaxP95Ms ms."
        }
    }
}
finally {
    $httpClient.Dispose()
    $handler.Dispose()
}

$passed = ($failures.Count -eq 0)
$resultText = "failed"

if ($passed) {
    $resultText = "passed"
}

$result = [ordered]@{
    baseUrl             = $BaseUrl
    result              = $resultText
    expectedSha         = $ExpectedSha
    reportedSha         = $reportedSha
    expectedEnvironment = $ExpectedEnvironment
    reportedEnvironment = $reportedEnvironment
    requests            = $Requests
    failedRequests      = $errorCount
    p95LatencyMs        = $p95
    maxP95LatencyMs     = $MaxP95Ms
    failures            = $failures
    testedAtUtc         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if ($OutputPath) {
    $folder = Split-Path -Parent $OutputPath

    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $OutputPath,
        ($result | ConvertTo-Json -Depth 5),
        (New-Object System.Text.UTF8Encoding $false)
    )
}

if ($passed) {
    Write-Host "SMOKE TEST PASSED: commit $reportedSha, environment $reportedEnvironment, p95 latency $p95 ms, $Requests/$Requests requests OK."
    exit 0
}

foreach ($failure in $failures) {
    Write-Host "##vso[task.logissue type=error]$failure"
}

Write-Host "SMOKE TEST FAILED."
exit 1
