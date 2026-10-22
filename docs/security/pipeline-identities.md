# Pipeline identities and permissions

| Identity | Type | Scope | Role | Why it needs it |
|---|---|---|---|---|
| `sc-azure-deployflow` (Entra app registration created by Azure DevOps) | Service principal using workload identity federation (no stored secret) | Resource group `rg-deployflow-manual-eus2` only | Contributor | Log in to ACR, push images and read the image digest |
| `ca-deployflow-manual` (system-assigned managed identity) | Managed identity | Container Registry `acrdeployflowammar03` | AcrPull | Pull the image at runtime without a password |
| `laptop-agent-01` | Self-hosted agent on the developer laptop | Agent pool `deployflow-laptop-pool` | Registered with a short-lived PAT, since revoked | Run pipeline jobs |

## Rules

- No passwords, keys or tokens are stored in the repository or in pipeline variables.
- Pull request runs execute tests only. They never log in to Azure and never push images.
- The GitHub repository is private. Pull requests from forks must not be built on the self-hosted agent.

## Known trade-offs (to tighten later)

- Contributor on the resource group is broader than required for pushing images. Milestone 3 replaces it with narrower roles managed by Terraform.
- The self-hosted agent runs on a personal laptop. Only trusted code from this private repository should ever run there.