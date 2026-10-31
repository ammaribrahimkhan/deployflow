<#
Rolls a Container App back to an earlier revision. Safe to run more than once (idempotent).

  -TargetRevision : revision to restore. Empty = the revision created just before the one
                    that currently serves the traffic.
  -Reason         : free text stored in the record
  -OutputPath     : rollback record JSON
  -RunUrl         : link to this pipeline run (stored in the record)

Runs inside an AzureCLI@2 task, so `az` is already signed in.
#>
param(
  [Parameter(Mandatory = $true)] [string]$AppName,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$OutputPath,
  [string]$TargetRevision = "",
  [string]$Reason = "manual rollback",
  [string]$RunUrl = ""
)

function Fail($message) {
  Write-Host "##vso[task.logissue type=error]$message"
  exit 1
}

# Windows PowerShell 5.1 returns a JSON array from ConvertFrom-Json as ONE nested object.
# This helper unpacks it so every revision is a separate item.
function Flatten($items) {
  foreach ($outer in $items) {
    foreach ($inner in $outer) {
      $inner
    }
  }
}

function Write-Record($record) {
  $folder = Split-Path -Parent $OutputPath
  if ($folder -and -not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
  [System.IO.File]::WriteAllText($OutputPath, ($record | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "##vso[task.setvariable variable=promotionReady]true"
}

# 1. What exists?
$revText = (az containerapp revision list --name $AppName --resource-group $ResourceGroup --query "[].{name:name, active:properties.active, created:properties.createdTime, traffic:properties.trafficWeight, image:properties.template.containers[0].image}" -o json | Out-String)
if ($LASTEXITCODE -ne 0) { Fail "Could not list the revisions of $AppName" }
$revisions = @(Flatten (ConvertFrom-Json $revText))
if ($revisions.Count -eq 0) { Fail "No revisions found for $AppName" }

# Explicitly cast 'created' to [DateTime] to make date comparison 100% accurate
$sorted = @($revisions | Sort-Object -Property { [DateTime]$_.created } -Descending)
Write-Host "Revisions (newest first):"
$sorted | Format-Table name, active, traffic, created -AutoSize | Out-String -Width 250 | Write-Host

$fqdn = (az containerapp show --name $AppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv | Out-String).Trim()
Write-Host "##vso[task.setvariable variable=appUrl]https://$fqdn"

# 2. Which revision serves the traffic now?
$current = @($revisions | Sort-Object -Property @{ Expression = "traffic"; Descending = $true }, @{ Expression = { [DateTime]$_.created }; Descending = $true }) | Select-Object -First 1
Write-Host "Currently serving: $($current.name) ($($current.traffic)%)"

# 3. Which revision do we go back to?
$target = $null
if (-not ([string]::IsNullOrWhiteSpace($TargetRevision)) -and $TargetRevision.Trim() -ne "previous") {

  $target = $revisions | Where-Object { $_.name -eq $TargetRevision.Trim() } | Select-Object -First 1
  if (-not $target) { Fail "Revision '$TargetRevision' does not exist. Check the list above." }
} else {
  Write-Host "TargetRevision parameter is empty. Dynamically evaluating previous standby revision..."
  # Look for the next available revision inside the existing list that is older than the current one
  $target = $sorted | Where-Object { [DateTime]$_.created -lt [DateTime]$current.created } | Select-Object -First 1
  
  # Fallback: If no older one exists via time but there are 2 revisions present, pick index 1
  if (-not $target -and $sorted.Count -gt 1) {
      $target = $sorted[1]
  }
  if (-not $target) { Fail "There is no earlier available revision to roll back to in this subscription." }
}
Write-Host "Rollback target safely resolved to: $($target.name)"

$record = [ordered]@{
  appName          = $AppName
  resourceGroup    = $ResourceGroup
  reason           = $Reason
  revisionBefore   = $current.name
  trafficBefore    = $current.traffic
  targetRevision   = $target.name
  targetImage      = $target.image
  outcome          = "started"
  rolledBackAtUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  rollbackRunUrl   = $RunUrl
}

# 4. Already done? Then there is nothing to do.
if (($current.name -eq $target.name) -and ($current.traffic -eq 100)) {
  $record.outcome = "noop_already_live"
  Write-Record $record
  Write-Host "Revision $($target.name) already serves 100% of the traffic. Nothing to do."
  exit 0
}

# 5. Activate the target if it was deactivated, then send it all the traffic.
if (-not $target.active) {
  Write-Host "Activating revision $($target.name) ..."
  az containerapp revision activate --name $AppName --resource-group $ResourceGroup --revision $target.name --output none
  if ($LASTEXITCODE -ne 0) { Fail "Could not activate revision $($target.name)" }
  Start-Sleep -Seconds 15
}

Write-Host "Sending 100% of the traffic to $($target.name) ..."
az containerapp ingress traffic set --name $AppName --resource-group $ResourceGroup --revision-weight "$($target.name)=100" --output none
if ($LASTEXITCODE -ne 0) { Fail "Could not change the traffic" }

# 6. Confirm, then deactivate the revision we rolled away from.
$trafficText = (az containerapp ingress traffic show --name $AppName --resource-group $ResourceGroup -o json | Out-String)
$trafficItems = @(Flatten (ConvertFrom-Json $trafficText))
$confirmed = $trafficItems | Where-Object { $_.revisionName -eq $target.name -and $_.weight -eq 100 }
if (-not $confirmed) { Fail "Traffic change could not be confirmed. Check the Revisions page in the Portal." }

if ($current.name -ne $target.name) {
  az containerapp revision deactivate --name $AppName --resource-group $ResourceGroup --revision $current.name --output none
}

$record.outcome = "rolled_back"
Write-Record $record
Write-Host "Rollback complete: $($target.name) serves 100% of the traffic."
exit 0
