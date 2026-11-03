# Dashboard identity and permissions

| Identity | Type | Scope | Role | Why |
|---|---|---|---|---|
| `id-deployflow-dashboard-eus2` | User-assigned managed identity | Subscription | Reader | Read apps, revisions and alerts |
| same | same | Platform, staging and production Log Analytics workspaces | Log Analytics Reader | Run the read-only KQL queries |
| same | same | Registry `acrdeployflowsharedammar03` | AcrPull | Pull its own image |
| same | Service principal user in Azure DevOps | Project `DeployFlow` | Readers group | Read pipeline runs and timelines |
| same (optional) | same | Pipelines `deployflow-cd`, `deployflow-rollback` | Queue builds | Only if actions are enabled |
| `sc-azure-deployflow` | Service connection | `rg-deployflow-dashboard-eus2` | Contributor | Deploy new dashboard images |

## Rules
- No secrets in the image, the repository or Terraform. The only secret is the platform-managed sign-in client secret.
- Every page and API call needs a signed-in user. Only `/healthz` is open.
- Actions are admin only, off by default, and still need the production approval in Azure DevOps.

## Limits
- The sign-in client secret expires and must be renewed.
- The managed identity can read all resources in the subscription (Reader). Narrow it to resource groups if the subscription grows.