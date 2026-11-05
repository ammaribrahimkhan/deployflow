# Architecture decision records

| # | Decision | Status |
|---|---|---|
| [0001](0001-terraform-remote-state.md) | Terraform state lives in Azure Storage with Entra authentication, versioning, soft delete and a delete lock | Accepted |
| [0002](0002-single-container-apps-environment.md) | One shared Container Apps environment, because the free subscription allows only one | Accepted |
| [0003](0003-security-gates-and-tool-pinning.md) | Security gates block the pipeline; the scanner is pinned by digest | Accepted |
| [0004](0004-promotion-by-digest-and-approvals.md) | CD never builds: it promotes the scanned digest, with an approval and branch check for production | Accepted |
| [0005](0005-progressive-delivery-and-automatic-rollback.md) | Canary release 10/50/100 with automatic rollback, and an idempotent rollback pipeline | Accepted |
| [0006](0006-observability-approach.md) | Structured logs, platform metrics and Application Insights events instead of an SDK for now | Accepted |
| [0007](0007-dashboard-design.md) | Read-only dashboard design, local one-time links, role-gated actions off by default | Accepted |
| [0008](0008-hosted-dashboard-and-sign-in.md) | Dashboard hosted on Container Apps with Entra sign-in and a read-only managed identity | Accepted |
| [0009](0009-cost-visibility-and-controlled-infrastructure-changes.md) | Honest cost views, budget, protected teardown, and an approval-gated Terraform pipeline | Accepted |

## Adding a new record

1. Copy the next number: `docs/adr/0010-short-title.md`.
2. Use the headings Status, Context, Decision, Consequences.
3. Add a row to the table above (the hygiene script checks this).