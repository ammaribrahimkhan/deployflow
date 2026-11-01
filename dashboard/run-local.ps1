<#
Starts the dashboard on this laptop, using your Azure CLI sign-in to read Azure and Azure DevOps.

  -EnableActions : allow admins to queue a deployment or a rollback from the page
                   (they still need the production approval in Azure DevOps)

Press Ctrl+C to stop it.
#>
param(
  [switch]$EnableActions
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

if (-not (Test-Path ".\.venv\Scripts\python.exe")) {
  Write-Host "Creating the virtual environment (first run only)..."
  py -m venv .venv
  .\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
}

if (-not (Test-Path ".\web\vendor\react.production.min.js")) {
  Write-Host "The React files are missing. Run this first: .\scripts\vendor-dashboard-assets.ps1 (from the project root)."
  exit 1
}

$subscription = (az account show --query id -o tsv | Out-String).Trim()
if (-not $subscription) {
  Write-Host "You are not signed in to Azure. Run: az login"
  exit 1
}

$env:AZURE_SUBSCRIPTION_ID = $subscription
$env:DASHBOARD_AUTH_MODE = "local"
if ($EnableActions) { $env:DASHBOARD_ACTIONS_ENABLED = "true" } else { $env:DASHBOARD_ACTIONS_ENABLED = "false" }

.\.venv\Scripts\python.exe main.py