# Pipeline identities and permissions

| Identity | Type | Scope | Role | Why it needs it |
|---|---|---|---|---|
| `sc-azure-deployflow` (Entra app registration created by Azure DevOps) | Service principal using workload identity federation (no stored secret) | Resource group `rg-deployflow-shared-eus2` | Contributor (assigned by Terraform, `infra/shared`) | Log in to the registry, push images, read the image digest |
| `id-deployflow-dev-eus2` | User-assigned managed identity | Registry `acrdeployflowsharedammar03` | AcrPull (assigned by Terraform) | Pull the image at runtime without a password |
| Developer (Ammar) | Human, Microsoft Entra sign-in | Subscription, plus the state storage account | Owner, Storage Blob Data Contributor | Run Terraform from the laptop |
| `laptop-agent-01` | Self-hosted agent on the developer laptop | Agent pool `deployflow-laptop-pool` | Registered once with a short-lived PAT, since revoked | Run pipeline jobs |

## Rules

- No passwords, keys or tokens are stored in the repository or in pipeline variables.
- Pull request runs execute tests and Terraform format/validate only. They never log in to Azure and never push images.
- The Terraform state storage account has shared-key access disabled: only Entra identities with a data role can read state.
- The GitHub repository is private. Pull requests from forks must not be built on the self-hosted agent.

## Known trade-offs (to tighten later)

- Contributor on the shared resource group is broader than strictly needed for pushing images. The group contains only the registry, so the blast radius is small. A narrower role is a candidate improvement once tested.
- Terraform is run from the developer laptop for now. Milestone 5 adds approval-gated pipeline runs.
- The self-hosted agent runs on a personal laptop. Only trusted code from this private repository should run there.