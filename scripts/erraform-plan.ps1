# Plans one Terraform stack, checks it is safe, and writes a summary. Changes NOTHING.
param(
  [Parameter(Mandatory = $true)] [string]$Stack,
  [Parameter(Mandatory = $true)] [string]$OutputDir,
  [string]$AlertEmail = "",
  [string]$DashboardAdmins = "",
  [string]$AllowDestroy = "false"
)

. (Join-Path $PSScriptRoot "terraform-common.ps1")

$allowedStacks = @("shared", "envs/dev", "envs/staging", "envs/prod", "envs/dashboard")
if ($allowedStacks -notcontains $Stack) { Fail "Unknown stack '$Stack'." }

Initialize-Terraform -Stack $Stack -AlertEmail $AlertEmail -DashboardAdmins $DashboardAdmins

$repoRoot = Split-Path -Parent $PSScriptRoot
$stackDir = Join-Path $repoRoot ("infra\" + $Stack.Replace("/", "\"))
if (-not (Test-Path $stackDir)) { Fail "Stack folder not found: $stackDir" }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$planFile = Join-Path $OutputDir "tfplan"

# Deleting these can lose data or break every other stack.
$protectedTypes = @(
  "azurerm_container_registry",
  "azurerm_storage_account",
  "azurerm_resource_group",
  "azurerm_log_analytics_workspace",
  "azurerm_container_app_environment"
)

Push-Location $stackDir
try {
  Invoke-TerraformInit

  terraform validate -no-color
  if ($LASTEXITCODE -ne 0) { Fail "terraform validate failed." }

  terraform plan -input=false -no-color -detailed-exitcode -out $planFile
  $planExit = $LASTEXITCODE
  if ($planExit -eq 1) { Fail "terraform plan failed." }

  $hasChanges = ($planExit -eq 2)
  $adds = 0
  $updates = 0
  $deletes = 0
  $protectedDeletes = @()

  if ($hasChanges) {
    terraform show -no-color $planFile | Out-File -FilePath (Join-Path $OutputDir "plan.txt") -Encoding utf8

    $planJson = (terraform show -json -no-color $planFile | Out-String) | ConvertFrom-Json

    foreach ($change in @($planJson.resource_changes)) {
      $actions = @($change.change.actions)
      if ($actions -contains "create") { $adds++ }
      if ($actions -contains "update") { $updates++ }
      if ($actions -contains "delete") {
        $deletes++
        if ($protectedTypes -contains $change.type) {
          $protectedDeletes += ($change.type + " " + $change.address)
        }
      }
    }
  } else {
    "No changes. The real infrastructure matches the code." | Out-File -FilePath (Join-Path $OutputDir "plan.txt") -Encoding utf8
  }

  $flag = "false"
  if ($hasChanges) { $flag = "true" }

  $summary = [ordered]@{
    stack            = $Stack
    hasChanges       = $hasChanges
    toAdd            = $adds
    toChange         = $updates
    toDestroy        = $deletes
    protectedDeletes = $protectedDeletes
    plannedAt        = (Get-Date).ToUniversalTime().ToString("o")
  }
  $summary | ConvertTo-Json | Out-File -FilePath (Join-Path $OutputDir "summary.json") -Encoding utf8

  Write-Host ""
  Write-Host "PLAN SUMMARY for ${Stack}: $adds to add, $updates to change, $deletes to destroy."

  Write-Host "##vso[task.setvariable variable=hasChanges;isOutput=true]$flag"

  if ($protectedDeletes.Count -gt 0 -and $AllowDestroy -ne "true") {
    $list = $protectedDeletes -join "; "
    Fail "The plan deletes protected resources ($list). Nothing was changed. If this is really intended, run the pipeline again with 'Allow the plan to delete protected resources' ticked."
  }
  if ($deletes -gt 0) {
    Write-Host "##vso[task.logissue type=warning]This plan destroys $deletes resource(s). Read plan.txt before approving."
  }
}
finally {
  Pop-Location
}