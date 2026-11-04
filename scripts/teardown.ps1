<#
Previews or performs a Terraform-based teardown of ONE DeployFlow stack.

Default = preview only (terraform plan -destroy). Nothing is deleted unless you add -Execute
AND type the confirmation phrase. This script never touches the Terraform state storage.

Usage:
  .\scripts\teardown.ps1 -Stack dev
  .\scripts\teardown.ps1 -Stack dev -Execute
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("dev", "dashboard", "staging", "prod", "shared")]
  [string]$Stack,

  [switch]$Execute
)

function Fail($message) {
  Write-Host $message -ForegroundColor Red
  exit 1
}

$folders = @{
  dev       = "infra\envs\dev"
  dashboard = "infra\envs\dashboard"
  staging   = "infra\envs\staging"
  prod      = "infra\envs\prod"
  shared    = "infra\shared"
}

$groups = @{
  dev       = "rg-deployflow-dev-eus2"
  dashboard = "rg-deployflow-dashboard-eus2"
  staging   = "rg-deployflow-staging-eus2"
  prod      = "rg-deployflow-prod-eus2"
  shared    = "rg-deployflow-shared-eus2"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$stackDir = Join-Path $repoRoot $folders[$Stack]

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  $env:PATH = "C:\Users\Hp\AppData\Local\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe;$env:PATH"
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { Fail "terraform was not found." }

$subscription = (az account show --query id -o tsv | Out-String).Trim()
if (-not $subscription) { Fail "Run: az login" }
$env:ARM_SUBSCRIPTION_ID = $subscription

# The shared stack holds the registry, the Container Apps environment and the platform logs.
# Everything else depends on it, so it can only go last.
if ($Stack -eq "shared") {
  $stillThere = @()
  foreach ($other in @("dev", "dashboard", "staging", "prod")) {
    if ((az group exists --name $groups[$other]) -eq "true") { $stillThere += $other }
  }
  if ($stillThere.Count -gt 0) {
    $names = $stillThere -join ", "
    Fail "Refusing: these stacks still exist: $names. Tear them down first (see docs\runbooks\teardown.md)."
  }
}

Write-Host ""
Write-Host "Stack: $Stack (resource group $($groups[$Stack]))"
switch ($Stack) {
  "prod"   { Write-Host "PRODUCTION. The resource group has prevent_destroy, so Terraform will refuse until you remove it on purpose." -ForegroundColor Yellow }
  "shared" { Write-Host "SHARED. Deleting it removes the registry and every image in it. The registry has prevent_destroy." -ForegroundColor Yellow }
}

# Placeholder values: a destroy plan does not use them, but Terraform still needs them to start.
$env:TF_VAR_pipeline_principal_object_id = "00000000-0000-0000-0000-000000000000"
$env:TF_VAR_image_tag = "teardown"
$env:TF_VAR_alert_email = "teardown@example.com"
$env:TF_VAR_admin_emails = ""

$planFile = "teardown.tfplan"

Push-Location $stackDir
try {
  $initialised = $false
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    terraform init -input=false -no-color
    if ($LASTEXITCODE -eq 0) { $initialised = $true; break }
    Write-Host "terraform init failed (attempt $attempt of 4)."
    if ($attempt -lt 4) { Start-Sleep -Seconds (20 * $attempt) }
  }
  if (-not $initialised) { Fail "terraform init failed." }

  terraform plan -destroy -input=false -no-color -out $planFile
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "The destroy plan was refused. If the message mentions prevent_destroy, a protection rule worked as intended." -ForegroundColor Yellow
    exit 1
  }

  if (-not $Execute) {
    Write-Host ""
    Write-Host "PREVIEW ONLY. Nothing was deleted. To delete, run: .\scripts\teardown.ps1 -Stack $Stack -Execute"
    exit 0
  }

  $phrase = "destroy $Stack"
  $typed = Read-Host "Type '$phrase' to delete this stack"
  if ($typed -ne $phrase) { Fail "Confirmation text did not match. Nothing was deleted." }

  if ($Stack -eq "prod" -or $Stack -eq "shared") {
    $second = Read-Host "This removes production or shared resources. Type 'I UNDERSTAND' to continue"
    if ($second -ne "I UNDERSTAND") { Fail "Not confirmed. Nothing was deleted." }
  }

  terraform apply -input=false -no-color $planFile
  if ($LASTEXITCODE -ne 0) { Fail "terraform destroy failed." }

  Write-Host ""
  Write-Host "Stack '$Stack' was removed. The Terraform state storage was not touched."
}
finally {
  if (Test-Path $planFile) { Remove-Item $planFile -Force }
  Pop-Location
}