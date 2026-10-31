<#
Runs one of the saved KQL queries from the monitoring\queries folder against a Log Analytics workspace.

  -QueryFile     : path to a .kql file
  -WorkspaceName : workspace to query (default: the shared platform workspace with the container logs)
  -ResourceGroup : its resource group
  -AppName       : replaces __APP_NAME__ in the query
  -Hours         : replaces __HOURS__ in the query (how far back to look)

Query files use single quotes only and no // comments, so they can be sent as one line.
#>
param(
  [Parameter(Mandatory = $true)] [string]$QueryFile,
  [string]$WorkspaceName = "log-deployflow-shared-eus2",
  [string]$ResourceGroup = "rg-deployflow-shared-eus2",
  [string]$AppName = "ca-deployflow-prod",
  [int]$Hours = 24
)

if (-not (Test-Path $QueryFile)) {
  Write-Host "Query file not found: $QueryFile"
  exit 1
}

az extension add --name log-analytics --only-show-errors 2>&1 | Out-Null

$customerId = (az monitor log-analytics workspace show --resource-group $ResourceGroup --workspace-name $WorkspaceName --query customerId -o tsv | Out-String).Trim()
if (-not $customerId) {
  Write-Host "Could not find the workspace $WorkspaceName in $ResourceGroup. Are you signed in (az login)?"
  exit 1
}

$lines = Get-Content $QueryFile | Where-Object { $_.Trim() -ne "" -and -not $_.TrimStart().StartsWith("//") }
$query = ($lines -join " ").Replace("__APP_NAME__", $AppName).Replace("__HOURS__", "$Hours")

Write-Host "Workspace: $WorkspaceName   App: $AppName   Last $Hours hours"
Write-Host ""

az monitor log-analytics query --workspace $customerId --analytics-query $query --output table