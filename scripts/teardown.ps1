
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "dashboard", "staging", "prod", "shared")]
    [string]$Stack,

    [switch]$Execute
)

$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message)
    Write-Host "##vso[task.logissue type=error]$Message"
    throw $Message
}

$stackFolders = @{
    dev       = "infra/envs/dev"
    dashboard = "infra/envs/dashboard"
    staging   = "infra/envs/staging"
    prod      = "infra/envs/prod"
    shared    = "infra/shared"
}

$resourceGroups = @{
    dev       = "rg-deployflow-dev-eus2"
    dashboard = "rg-deployflow-dashboard-eus2"
    staging   = "rg-deployflow-staging-eus2"
    prod      = "rg-deployflow-prod-eus2"
    shared    = "rg-deployflow-shared-eus2"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$stackPath = Join-Path $repoRoot $stackFolders[$Stack]
$resourceGroup = $resourceGroups[$Stack]

if (-not (Test-Path $stackPath)) {
    Fail "Terraform stack folder not found: $stackPath"
}

Push-Location $stackPath

try {
    # Find Terraform without relying on a machine-specific Windows path.
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        $wingetPackages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"

        if (Test-Path $wingetPackages) {
            $terraformExe = Get-ChildItem `
                -Path $wingetPackages `
                -Filter "terraform.exe" `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($terraformExe) {
                $env:PATH = "$($terraformExe.DirectoryName);$env:PATH"
            }
        }
    }

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        Fail "Terraform was not found. Install Terraform or add it to PATH."
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Fail "Azure CLI was not found. Install Azure CLI and sign in."
    }

    # Confirm Azure CLI authentication and subscription.
    $subscriptionId = az account show --query id -o tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        Fail "Azure CLI is not signed in. Run az login and select the correct subscription."
    }

    $env:ARM_SUBSCRIPTION_ID = $subscriptionId

    Write-Host "Using subscription: $subscriptionId"
    Write-Host "Selected stack: $Stack"
    Write-Host "Resource group: $resourceGroup"

    # Protect the shared stack while dependent environments still exist.
    if ($Stack -eq "shared") {
        $dependentStacks = @(
            "rg-deployflow-dev-eus2",
            "rg-deployflow-dashboard-eus2",
            "rg-deployflow-staging-eus2",
            "rg-deployflow-prod-eus2"
        )

        foreach ($rg in $dependentStacks) {
            $exists = az group exists --name $rg

            if ($LASTEXITCODE -ne 0) {
                Fail "Could not check whether resource group $rg exists."
            }

            if ($exists -eq "true") {
                Fail "Shared teardown blocked: dependent resource group $rg still exists."
            }
        }
    }

    if ($Stack -eq "prod" -or $Stack -eq "shared") {
        Write-Warning "You selected the sensitive '$Stack' stack."
        Write-Warning "Review every planned deletion carefully."
    }

    # Use harmless placeholder values for optional Terraform variables.
    $env:TF_VAR_alert_email = ""
    $env:TF_VAR_admin_emails = ""
    $env:TF_VAR_image_tag = "teardown-placeholder"
    $env:TF_VAR_pipeline_principal_object_id = "00000000-0000-0000-0000-000000000000"

    # Initialize Terraform using the configured remote backend.
    $initSucceeded = $false

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Write-Host "Terraform init attempt $attempt of 4"

        terraform init -input=false -no-color

        if ($LASTEXITCODE -eq 0) {
            $initSucceeded = $true
            break
        }

        if ($attempt -lt 4) {
            Start-Sleep -Seconds 15
        }
    }

    if (-not $initSucceeded) {
        Fail "Terraform init failed after 4 attempts."
    }

    # Generate a destroy plan. This does not delete resources.
    $planFile = "teardown.tfplan"

    terraform plan `
        -destroy `
        -input=false `
        -no-color `
        -out=$planFile

    if ($LASTEXITCODE -ne 0) {
        Fail "Terraform destroy plan failed. No resources were deleted."
    }

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "DESTROY PLAN CREATED"
    Write-Host "Stack: $Stack"
    Write-Host "Resource group: $resourceGroup"
    Write-Host "=========================================="
    Write-Host ""

    terraform show -no-color $planFile

    if ($LASTEXITCODE -ne 0) {
        Fail "Could not display the destroy plan."
    }

    # Preview-only by default.
    if (-not $Execute) {
        Write-Host ""
        Write-Host "PREVIEW ONLY: No resources were deleted."
        Write-Host "To execute, rerun with -Execute after reviewing the plan."
        return
    }

    Write-Host ""
    Write-Warning "You are about to execute Terraform destroy for '$Stack'."

    $confirmation = Read-Host "Type 'destroy $Stack' to continue"

    if ($confirmation -cne "destroy $Stack") {
        Write-Host "Confirmation did not match. Destroy cancelled."
        return
    }

    # Require an additional confirmation for production/shared.
    if ($Stack -eq "prod" -or $Stack -eq "shared") {
        $finalConfirmation = Read-Host "Type 'I UNDERSTAND' for the final confirmation"

        if ($finalConfirmation -cne "I UNDERSTAND") {
            Write-Host "Final confirmation did not match. Destroy cancelled."
            return
        }
    }

    Write-Warning "Executing Terraform destroy for stack '$Stack'..."

    terraform apply -input=false -auto-approve -no-color $planFile

    if ($LASTEXITCODE -ne 0) {
        Fail "Terraform destroy failed. Review the Terraform output."
    }

    Write-Host "Terraform destroy completed for stack '$Stack'."
}
finally {
    # Remove only the local plan file. Remote Terraform state is retained.
    if (Test-Path "teardown.tfplan") {
        Remove-Item "teardown.tfplan" -Force -ErrorAction SilentlyContinue
    }

    Pop-Location
}
