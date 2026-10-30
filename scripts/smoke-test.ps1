<#
Smoke test for a deployed DeployFlow app.

Checks, in order:
  1. /health reports "healthy" (retries while the app starts or scales up from zero)
  2. /api/info shows the expected environment name, and the expected commit when -ExpectedSha is given
  3. A burst of requests: every request succeeds and the 95th percentile latency is within the limit

Writes a JSON result file (optional). Exit code 0 = pass, 1 = fail.
#>
param(
  [Parameter(Mandatory = $true)] [string]$BaseUrl,
  [string]$ExpectedSha = "",
  [Parameter(Mandatory = $true)] [string]$ExpectedEnvironment,
  [int]$WarmupSeconds = 180,
  [int]$Requests = 20,
  [int]$MaxP95Ms = 1500,
  [string]$OutputPath = ""
)

$BaseUrl = $BaseUrl.TrimEnd("/")
$failures = @()

function Get-Json($url) {
  $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
  if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
  return ($response.Content | ConvertFrom-Json)
}

# 1. Wait for the app to become healthy (handles start-up and scale-from-zero).
Write-Host "1/3 Waiting for $BaseUrl/health to report healthy (up to $WarmupSeconds seconds)..."
$healthy = $false
$lastError = ""
$deadline = (Get-Date).AddSeconds($WarmupSeconds)
while ((Get-Date) -lt $deadline) {
  try {
    $health = Get-Json "$BaseUrl/health"
    if ($health.status -eq "healthy") { $healthy = $true; break }
    $lastError = "status was '$($health.status)'"
  } catch {
    $lastError = $_.Exception.Message
  }
  Start-Sleep -Seconds 3
}

# 2. Right environment, and right commit when one is expected.
$reportedSha = $null
$reportedEnvironment = $null
if ($healthy) {
  Write-Host "2/3 Checking /api/info..."
  try {
    $info = Get-Json "$BaseUrl/api/info"
    $reportedSha = $info.gitSha
    $reportedEnvironment = $info.environment
    if ($ExpectedSha -and ($reportedSha -ne $ExpectedSha)) {
      $failures += "Wrong commit: the app reports '$reportedSha' but '$ExpectedSha' was expected"
    }
    if ($reportedEnvironment -ne $ExpectedEnvironment) {
      $failures += "Wrong environment: the app reports '$reportedEnvironment' but '$ExpectedEnvironment' was expected"
    }
  } catch {
    $failures += "Could not read /api/info: $($_.Exception.Message)"
  }
}

# 3. A burst of requests: all must succeed, and latency must be acceptable.
$latencies = @()
$errorCount = 0
$p95 = $null
if ($healthy) {
  Write-Host "3/3 Sending $Requests requests..."
  for ($i = 1; $i -le $Requests; $i++) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $null = Get-Json "$BaseUrl/health"
    } catch {
      $errorCount++
    }
    $stopwatch.Stop()
    $latencies += [int]$stopwatch.ElapsedMilliseconds
  }
  $sorted = @($latencies | Sort-Object)
  $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
  $p95 = $sorted[$index]
  if ($errorCount -gt 0) { $failures += "$errorCount of $Requests requests failed" }
  if ($p95 -gt $MaxP95Ms) { $failures += "95th percentile latency was $p95 ms, above the limit of $MaxP95Ms ms" }
} else {
  $failures += "The app never became healthy within $WarmupSeconds seconds. Last error: $lastError"
}

$passed = ($failures.Count -eq 0)
$resultText = "failed"
if ($passed) { $resultText = "passed" }

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
  if ($folder -and -not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
  [System.IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
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