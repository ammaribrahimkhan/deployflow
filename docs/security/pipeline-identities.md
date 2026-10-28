# Pipeline identities and permissions

| Identity | Type | Scope | Role | Why it needs it |
|---|---|---|---|---|
| `sc-azure-deployflow` (Entra app registration created by Azure DevOps) | Service principal using workload identity federation (no stored secret) | `rg-deployflow-shared-eus2` | Contributor (Terraform: `infra/shared`) | CI pushes images to the registry; deployments reference the shared Container Apps environment |
| `sc-azure-deployflow` | same | `rg-deployflow-staging-eus2` | Contributor (Terraform: `infra/envs/staging`) | CD updates the staging app |
| `sc-azure-deployflow` | same | `rg-deployflow-prod-eus2` | Contributor (Terraform: `infra/envs/prod`) | CD updates the production app |
| `id-deployflow-dev-eus2`, `id-deployflow-staging-eus2`, `id-deployflow-prod-eus2` | User-assigned managed identities | Registry `acrdeployflowsharedammar03` | AcrPull (Terraform) | Pull images at runtime without a password |
| Developer (Ammar) | Human, Microsoft Entra sign-in | Subscription, plus the state storage account | Owner, Storage Blob Data Contributor | Run Terraform from the laptop |
| `laptop-agent-01` | Self-hosted agent on the developer laptop | Agent pool `deployflow-laptop-pool` | Registered once with a short-lived PAT, since revoked | Run pipeline jobs |

## Rules

- No passwords, keys or tokens are stored in the repository or in pipeline variables.
- Pull request runs never log in to Azure, never push images and never deploy. The CD pipeline has `pr: none`.
- Production deployments require manual approval and a branch check (`main` only) on the Azure DevOps environment `production`.
- Production only receives the image digest that passed the staging smoke test. The deploy script refuses a different digest.
- Only builds from `main` whose security gate passed can be deployed.
- The Terraform state storage account has shared-key access disabled.
- The GitHub repository is private. Pull requests from forks must not be built on the self-hosted agent.

## Known trade-offs (to tighten later)

- One pipeline identity deploys to both staging and production. Production is protected by approvals and checks, not by a separate identity. A separate service connection per environment is the next improvement.
- Contributor on a resource group is broader than strictly needed for updating one app.
- Terraform is run from the developer laptop. A controlled infrastructure pipeline with approvals comes in Milestone 9.
- The self-hosted agent runs on a personal laptop. Only trusted code from this private repository should run there.