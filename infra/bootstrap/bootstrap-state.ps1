<#
Creates the Azure Storage account that holds Terraform state.
Run once. Safe to re-run: existing resources are updated, not duplicated.

Protections:
  - no anonymous/public blob access, HTTPS only, TLS 1.2 minimum
  - shared-key access DISABLED (only Microsoft Entra identities can read/write state)
  - blob versioning + 14-day soft delete (recover from mistakes)
  - CanNotDelete lock on the resource group
#>

$location       = "eastus"
$resourceGroup  = "rg-deployflow-tfstate-eus2"
$storageAccount = "stdfstateammar03"
$container      = "tfstate"

function Check($what) {
  if ($LASTEXITCODE -ne 0) { throw "FAILED: $what" }
}

Write-Host "1/7 Creating resource group..."
az group create --name $resourceGroup --location $location --tags project=deployflow managed_by=bootstrap | Out-Null
Check "resource group"

Write-Host "2/7 Creating storage account..."
az storage account create --name $storageAccount --resource-group $resourceGroup --location $location --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --https-only true --tags project=deployflow managed_by=bootstrap | Out-Null
Check "storage account (is the name already taken?)"

Write-Host "3/7 Creating blob container..."
az storage container create --name $container --account-name $storageAccount --auth-mode key | Out-Null
Check "blob container"

Write-Host "4/7 Enabling versioning and soft delete..."
az storage account blob-service-properties update --account-name $storageAccount --resource-group $resourceGroup --enable-versioning true --enable-delete-retention true --delete-retention-days 14 --enable-container-delete-retention true --container-delete-retention-days 14 | Out-Null
Check "versioning and soft delete"

Write-Host "5/7 Disabling shared-key access..."
az storage account update --name $storageAccount --resource-group $resourceGroup --allow-shared-key-access false | Out-Null
Check "disable shared key"

Write-Host "6/7 Granting you access to the state data..."
$accountId = az storage account show --name $storageAccount --resource-group $resourceGroup --query id -o tsv
Check "read storage account id"
$userId = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $userId) {
  Write-Warning "Could not look up your user id. Add the role in the Portal instead:"
  Write-Warning "Storage account > Access control (IAM) > Add > Add role assignment > Storage Blob Data Contributor > Members > + Select members > pick yourself > Review + assign"
} else {
  az role assignment create --assignee-object-id $userId --assignee-principal-type User --role "Storage Blob Data Contributor" --scope $accountId | Out-Null
  Check "role assignment"
}

Write-Host "7/7 Locking the resource group against deletion..."
az lock create --name lock-tfstate --lock-type CanNotDelete --resource-group $resourceGroup --notes "Protects Terraform state. Remove only on purpose." | Out-Null
Check "resource lock"

Write-Host ""
Write-Host "Done. Wait about 5 minutes before running terraform init (role assignments take time to spread)."