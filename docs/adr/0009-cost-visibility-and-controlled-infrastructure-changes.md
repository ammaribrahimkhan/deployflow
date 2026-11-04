# ADR 0009: Cost visibility, teardown and controlled infrastructure changes

## Status
Accepted

## Context
The platform must show what it costs without pretending to know more than it does, warn before money is wasted, be removable without losing shared data, and change infrastructure only through a reviewed, approved path.

## Decision
- The dashboard shows actual cost from Azure Cost Management when the subscription type and the dashboard identity allow it. Otherwise it shows an estimate range, labelled as an estimate, calculated from the resources that exist and approximate public prices.
- Cost data is delayed by hours, is cached for ten minutes, and is described that way on the page.
- A monthly budget with email notifications at 50, 80 and 100 percent (actual) and at 100 percent (forecast) is defined in Terraform. Budgets warn; they do not stop spending.
- Idle detection counts real requests (health checks excluded) per app over seven days, plus active revisions that receive no traffic.
- Teardown is one stack at a time with `scripts/teardown.ps1`: preview by default, typed confirmation to execute, refusal to remove the shared stack while others exist, and protection rules (`prevent_destroy`, a lock on the state storage) that the script never bypasses.
- Infrastructure changes go through `deployflow-infra-apply`: plan, safety checks (protected deletes are blocked), published plan, human approval on the `infrastructure` environment, then apply of that exact saved plan. It uses its own service connection, restricted to the main branch.

## Consequences
- Estimates are approximate and must never be quoted as bills.
- The infrastructure service connection is powerful (Contributor and User Access Administrator on the subscription). It is protected by branch control, an approval check and pipeline permissions limited to one pipeline. A split into a read-only plan identity and an approval-gated apply identity would be stronger.
- Plan files can contain variable values (for example an email address) and are stored as pipeline artifacts inside the project.