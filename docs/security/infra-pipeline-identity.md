# Infrastructure pipeline identity

| Item | Setting |
|---|---|
| Service connection | `sc-azure-terraform` (workload identity federation, no stored secret) |
| Roles | Contributor and User Access Administrator on the subscription; Storage Blob Data Contributor on the state storage account |
| Pipeline permission | Only `deployflow-infra-apply` |
| Checks on the connection | Branch control: `refs/heads/main` only |
| Approval | Environment `infrastructure` needs a human approval before every apply |
| Safety | The plan stage blocks deletion of registries, storage, resource groups, workspaces and environments unless explicitly allowed |

The dashboard identity also has **Cost Management Reader** (read cost data and budgets, nothing else).

## Limits
- The identity is powerful because Terraform creates role assignments. Keep the approval and branch checks.
- Splitting plan (read-only) and apply (approval-gated) into two identities would be stronger.