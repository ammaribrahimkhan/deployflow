
# Shared helpers for the infrastructure pipeline scripts.

function Fail($message) {
  Write-Host "##vso[task.logissue type=error]$message"
  exit 1
}

function Initialize-Terraform {
  param(
    [Parameter(Mandatory = $true)] [string]$Stack,
    [string]$AlertEmail = "",
    [string]$DashboardAdmins = ""
  )

  # A pipeline variable that was never defined stays as literal text "$(name)".
  if ($AlertEmail -like '$(*') { $AlertEmail = "" }
  if ($DashboardAdmins -like '$(*') { $DashboardAdmins = "" }

  # Find Terraform without relying on a personal Windows user path.
  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    $terraformExe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" `
      -Filter terraform.exe -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1

    if ($terraformExe) {
      $env:PATH = "$($terraformExe.DirectoryName);$env:PATH"
    }
  }

  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Fail "terraform was not found on this agent."
  }

  $cache = "C:\terraform-plugin-cache"
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  $env:TF_PLUGIN_CACHE_DIR = $cache
  $env:TF_IN_AUTOMATION = "true"

  $subscription = (az account show --query id -o tsv | Out-String).Trim()
  if (-not $subscription) {
    Fail "Not signed in to Azure."
  }

  $env:ARM_SUBSCRIPTION_ID = $subscription

  $principal = (az role assignment list --resource-group rg-deployflow-shared-eus2 --query "[?roleDefinitionName=='Contributor' && principalType=='ServicePrincipal'].principalId | [0]" -o tsv | Out-String).Trim()

  if (-not $principal) {
    Fail "Could not find the application deployment service principal."
  }

  # Variables that a stack does not declare are ignored by Terraform.
  $env:TF_VAR_pipeline_principal_object_id = $principal
  $env:TF_VAR_alert_email = $AlertEmail
  $env:TF_VAR_admin_emails = $DashboardAdmins

  if ($Stack -eq "shared" -and -not $AlertEmail) {
    Fail "The pipeline variable alertEmail is not set (pipeline > Edit > Variables)."
  }

  $repository = "deployflow-app"

  if ($Stack -eq "envs/dashboard") {
    $repository = "deployflow-dashboard"
  }

  $tag = (az acr repository show-tags --name acrdeployflowsharedammar03 --repository $repository --orderby time_desc --top 1 -o tsv | Out-String).Trim()

  if (-not $tag) {
    Fail "Could not read the newest image tag of $repository."
  }

  $env:TF_VAR_image_tag = $tag
}

function Invoke-TerraformInit {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    terraform init -input=false -no-color

    if ($LASTEXITCODE -eq 0) {
      return
    }

    Write-Host "terraform init failed (attempt $attempt of 4)."

    if ($attempt -lt 4) {
      Start-Sleep -Seconds (20 * $attempt)
    }
  }

  Fail "terraform init failed after 4 attempts (network problem?)."
}
