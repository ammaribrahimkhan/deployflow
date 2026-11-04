# Cost and resources

## What costs money (approximate, check Azure pricing for real numbers)
| Resource | Roughly | Notes |
|---|---|---|
| Container registry (Basic) | about 5 USD per month | Fixed charge while it exists |
| Availability test (production) | about 1.40 USD per month | Per run; stop it to save |
| Log search alert rules | about 0.50 to 3 USD each | Depends on how often they run |
| Metric alert rules | 0 to 0.50 USD each | First time series free |
| Log Analytics workspaces | 0 to a few USD each | First 5 GB per month free, daily cap set |
| Container apps | usually 0 | Scale to zero, free monthly grant |
| Storage account (state) | cents | A few small blobs |
| Managed identities, resource groups, action groups | 0 | No charge |

## Reading the dashboard
- Green notice: actual cost from Azure Cost Management, delayed by hours.
- Plain notice: ESTIMATE range, not a billed amount.
- "Candidate to remove": no requests for seven days (health checks excluded).
- "Protected": removing this resource group by accident would hurt (state, shared, production).

## Ways to spend less
1. Remove the dev environment with `scripts\teardown.ps1 -Stack dev -Execute`.
2. Keep apps at minimum zero replicas.
3. Stop the availability test when you are not demonstrating.
4. Delete old container revisions that receive no traffic.
5. Watch the budget emails.