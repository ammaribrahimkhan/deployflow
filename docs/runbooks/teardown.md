# Teardown runbook

Always preview first: `.\scripts\teardown.ps1 -Stack <name>`. It prints what would be deleted and deletes nothing.

## Order
1. `dashboard`
2. `dev`
3. `staging`
4. `prod` (see below)
5. `shared` (only when the others are gone; the script refuses otherwise)
6. State storage (manual, last)
7. Optional: Entra app registrations (dashboard sign-in, service connections), Azure DevOps project, GitHub repository, budget.

## What protects you
- `prod` resource group has `prevent_destroy`. To really remove production, set `prevent_destroy = false` in `infra/envs/prod/main.tf`, apply, then run teardown with `-Execute` and both confirmations.
- The shared registry has `prevent_destroy`. Deleting it deletes every image.
- The state storage has a CanNotDelete lock and versioning. The script never touches it. To remove it at the very end: delete the lock in the Portal, then delete `rg-deployflow-tfstate-eus2`. This erases all Terraform state.
- Nothing in these stacks holds user data. Logs and images are the only things lost.

## After a teardown
- `terraform plan` in the removed stack shows everything as "to add". That is expected.
- Re-create any stack with the infrastructure pipeline or `terraform apply`.