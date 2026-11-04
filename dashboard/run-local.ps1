# Starts the DeployFlow dashboard on this computer (local mode).
# Uses your own Azure sign-in (az login). A browser tab opens by itself.

Set-Location $PSScriptRoot

if (-not (Test-Path ".\.venv\Scripts\python.exe")) {
  Write-Host "Creating the Python virtual environment..."
  py -m venv .venv
  if ($LASTEXITCODE -ne 0) { Write-Host "Could not create the virtual environment." -ForegroundColor Red; exit 1 }
}

.\.venv\Scripts\python.exe -m pip install -q -r requirements.txt
if ($LASTEXITCODE -ne 0) { Write-Host "Dependency installation failed." -ForegroundColor Red; exit 1 }

$account = az account show --query id -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $account) {
  Write-Host "You are not signed in to Azure. Run: az login" -ForegroundColor Red
  exit 1
}

$env:DASHBOARD_AUTH_MODE = "local"
$env:AZURE_SUBSCRIPTION_ID = $account.Trim()
$env:DEVOPS_ORGANIZATION = "deployflow-ammar03"
$env:DEVOPS_PROJECT = "DeployFlow"

.\.venv\Scripts\python.exe server.py