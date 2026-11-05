# Limitations and roadmap

Honest scope, so nobody mistakes this for more than it is.

## Limitations

- **Synthetic checks.** Canary decisions use probes sent by the pipeline, not real user traffic. They catch crashes, errors and slowness, not subtle logic or data bugs ([ADR 0005](adr/0005-progressive-delivery-and-automatic-rollback.md)).
- **No database.** Migration strategy is written down (expand and contract) but not implemented.
- **One region, one shared environment.** No redundancy. The shared environment is a blast-radius trade-off forced by the free tier ([ADR 0002](adr/0002-single-container-apps-environment.md)).
- **Self-hosted agent on a laptop.** Pipelines depend on that laptop being awake. The agent is a trust boundary and is not hardened like an ephemeral build pool.
- **Powerful infrastructure identity.** `sc-azure-terraform` can change the subscription. It is protected by approval, branch control and pipeline permission, but a split between a read-only plan identity and an approval-gated apply identity would be stronger.
- **Dashboard.** One replica with an in-memory cache. Any member of the Entra tenant can sign in as a viewer. The sign-in client secret expires and must be renewed.
- **SLOs.** Traffic is mostly synthetic and very low, so percentages are noisy and error budgets are illustrative.
- **Cost.** Actual cost depends on what the subscription exposes and is delayed by hours. Estimates are ranges from assumed prices, never bills.
- **Plan artifacts.** Saved Terraform plans can contain variable values (such as an email address) and live inside the Azure DevOps project.
- **Fault injection.** `FAULT_INJECTION_PERCENT` is a demo hook that exists in the sample app on purpose. It is off by default and documented.
- **Alert tuning.** The unhealthy-revision fix is not yet validated across a full release cycle (see the [incident report](incidents/2026-11-01-noisy-unhealthy-revision-alert.md)).

## Roadmap

1. Ephemeral build agents (scale set or hosted pool) instead of a laptop.
2. Split Terraform identities: read-only plan, approval-gated apply.
3. Application Insights SDK or OpenTelemetry for traces and the application map ([ADR 0006](adr/0006-observability-approach.md)).
4. Real traffic gates: promote on SLO burn rate from real metrics, not only probes.
5. A database with tested expand and contract migrations and snapshot before migrate.
6. Private networking, WAF and a custom domain for the dashboard.
7. Multiple regions with traffic failover.
8. Branch protection and required reviews on GitHub, and signed commits.
9. Policy as code (Azure Policy or OPA) for resource rules.
10. Cost: tag-based cost allocation and automatic scale-down of idle environments.