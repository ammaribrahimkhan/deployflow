<#
Records a deployment (or a rollback) as a custom event in Application Insights, so a release
can be lined up with logs, metrics and alerts.

  -AppInsightsName : name of the environment's Application Insights resource
  -ResourceGroup   : its resource group
  -RecordPath      : promotion record or rollback record JSON written by the release scripts
  -EnvironmentName : staging or production
  -EventName       : "Deployment" or "Rollback"
  -JobStatus       : the pipeline's job status so far (used when the record has no outcome)
  -RunUrl          : link to this pipeline run

Best effort: a telemetry problem never fails a release. This script always exits with code 0.
Runs inside an AzureCLI@2 task, so `az` is already signed in (it only reads the Application
Insights resource, it does not store any key).
#>
param(
  [Parameter(Mandatory = $true)] [string]$AppInsightsName,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$RecordPath,
  [Parameter(Mandatory = $true)] [string]$EnvironmentName,
  [string]$EventName = "Deployment",
  [string]$JobStatus = "",
  [string]$RunUrl = ""
)

function Warn($message) {
  Write-Host "##vso[task.logissue type=warning]$message"
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  if (-not (Test-Path $RecordPath)) {
    Warn "No record found at $RecordPath. No deployment event was sent."
    exit 0
  }
  $record = Get-Content $RecordPath -Raw | ConvertFrom-Json

  # What happened?
  $outcome = $null
  if ($record.PSObject.Properties.Name -contains "outcome") { $outcome = [string]$record.outcome }
  if (-not $outcome) {
    if ($JobStatus -eq "Failed" -or $JobStatus -eq "Canceled") {
      $outcome = "failed"
    } elseif ($record.PSObject.Properties.Name -contains "alreadyDeployed" -and $record.alreadyDeployed -eq $true) {
      $outcome = "already_deployed"
    } else {
      $outcome = "deployed"
    }
  }

  # Find where to send the event.
  $connectionString = (az resource show --resource-group $ResourceGroup --name $AppInsightsName --resource-type "microsoft.insights/components" --query "properties.ConnectionString" -o tsv | Out-String).Trim()
  $instrumentationKey = $null
  $endpoint = "https://dc.services.visualstudio.com/"
  if ($connectionString -match "InstrumentationKey=([^;]+)") { $instrumentationKey = $Matches[1] }
  if ($connectionString -match "IngestionEndpoint=([^;]+)") { $endpoint = $Matches[1] }
  if (-not $instrumentationKey) {
    $instrumentationKey = (az resource show --resource-group $ResourceGroup --name $AppInsightsName --resource-type "microsoft.insights/components" --query "properties.InstrumentationKey" -o tsv | Out-String).Trim()
  }
  if (-not $instrumentationKey) {
    Warn "Could not read the Application Insights key for $AppInsightsName. No deployment event was sent."
    exit 0
  }
  if (-not $endpoint.EndsWith("/")) { $endpoint = $endpoint + "/" }

  # Every simple value in the record becomes a property of the event.
  $properties = [ordered]@{}
  foreach ($item in $record.PSObject.Properties) {
    $value = $item.Value
    if ($null -eq $value) { continue }
    if ($value -is [string] -or $value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal] -or $value -is [bool]) {
      $properties[$item.Name] = [string]$value
    }
  }
  $properties["environment"] = $EnvironmentName
  $properties["outcome"] = $outcome
  $properties["jobStatus"] = $JobStatus
  $properties["pipelineRunUrl"] = $RunUrl

  $measurements = [ordered]@{}
  if ($record.PSObject.Properties.Name -contains "steps") {
    $measurements["canarySteps"] = @($record.steps).Count
  }

  $envelope = [ordered]@{
    name = "Microsoft.ApplicationInsights.Event"
    time = (Get-Date).ToUniversalTime().ToString("o")
    iKey = $instrumentationKey
    tags = [ordered]@{ "ai.cloud.role" = "deployflow-release" }
    data = [ordered]@{
      baseType = "EventData"
      baseData = [ordered]@{
        ver          = 2
        name         = $EventName
        properties   = $properties
        measurements = $measurements
      }
    }
  }
  $json = $envelope | ConvertTo-Json -Depth 8 -Compress

  $uri = $endpoint + "v2/track"
  $sent = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType "application/json; charset=utf-8" -TimeoutSec 20
      if ($response.itemsAccepted -ge 1) {
        $sent = $true
        break
      }
      Write-Host "Application Insights did not accept the event (attempt $attempt of 3)."
    } catch {
      Write-Host "Sending the event failed (attempt $attempt of 3): $($_.Exception.Message)"
    }
    if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
  }

  if ($sent) {
    Write-Host "Deployment event '$EventName' recorded in $AppInsightsName (environment $EnvironmentName, outcome $outcome)."
  } else {
    Warn "The deployment event could not be sent to Application Insights. The release itself is not affected."
  }
} catch {
  Warn "Deployment event step failed: $($_.Exception.Message). The release itself is not affected."
}

exit 0