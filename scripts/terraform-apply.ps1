# Applies a plan that was already created and approved. Terraform refuses a stale plan.
param(
  [Parameter(Mandatory = $true)] [string]$Stack,
  [Parameter(Mandatory = $true)] [string]$PlanPath,
  [string]$AlertEmail = "",
  [string]$DashboardAdmins = ""
)

. (Join-Path $PSScriptRoot "terraform-common.ps1")

$allowedStacks = @("shared", "envs/dev", "envs/staging", "envs/prod", "envs/dashboard")
if ($allowedStacks -notcontains $Stack) { Fail "Unknown stack '$Stack'." }
if (-not (Test-Path $PlanPath)) { Fail "The approved plan file was not found: $PlanPath" }

Initialize-Terraform -Stack $Stack -AlertEmail $AlertEmail -DashboardAdmins $DashboardAdmins

$repoRoot = Split-Path -Parent $PSScriptRoot
$stackDir = Join-Path $repoRoot ("infra\" + $Stack.Replace("/", "\"))

Push-Location $stackDir
try {
  Invoke-TerraformInit

  terraform apply -input=false -no-color $PlanPath
  if ($LASTEXITCODE -ne 0) {
    Fail "terraform apply failed. If the message says the saved plan is stale, something changed since the plan: run the pipeline again."
  }

  terraform output -no-color
}
finally {
  Pop-Location
}