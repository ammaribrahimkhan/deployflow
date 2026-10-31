<#
Sends a stream of requests to an app so there is something to measure, and prints a summary.

  -BaseUrl  : for example https://ca-deployflow-prod.<something>.eastus2.azurecontainerapps.io
  -Requests : how many requests to send
  -DelayMs  : pause between requests
  -Path     : endpoint to call ("/" is the business endpoint; "/health" is the health check)
#>
param(
  [Parameter(Mandatory = $true)] [string]$BaseUrl,
  [int]$Requests = 100,
  [int]$DelayMs = 300,
  [string]$Path = "/"
)

$url = $BaseUrl.TrimEnd("/") + $Path
$statusCounts = @{}
$latencies = @()

Write-Host "Sending $Requests requests to $url ..."

for ($i = 1; $i -le $Requests; $i++) {
  $code = 0
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
    $code = [int]$response.StatusCode
  } catch {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
  }
  $stopwatch.Stop()

  $latencies += [int]$stopwatch.ElapsedMilliseconds
  $key = "$code"
  if ($statusCounts.ContainsKey($key)) { $statusCounts[$key] = $statusCounts[$key] + 1 } else { $statusCounts[$key] = 1 }

  if ($i % 25 -eq 0) { Write-Host "  $i / $Requests sent" }
  Start-Sleep -Milliseconds $DelayMs
}

$sorted = @($latencies | Sort-Object)
$p50 = $sorted[[math]::Ceiling(0.50 * $sorted.Count) - 1]
$p95 = $sorted[[math]::Ceiling(0.95 * $sorted.Count) - 1]

Write-Host ""
Write-Host "Done. Status codes (0 means no response):"
$statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("  {0} : {1}" -f $_.Name, $_.Value) }
Write-Host "Latency seen from this laptop: p50 $p50 ms, p95 $p95 ms"