# Screenshot checklist

Save each image as PNG in this folder with the exact name. Capture at a readable size (browser at 100% zoom) and crop to the relevant area.

## Before you share anything: hide private details

Cover with a solid rectangle (Snipping Tool > pen, or Paint > rectangle fill): subscription IDs, tenant IDs, object IDs, your email address, personal URLs and the dashboard's full hostname if you do not want it public. Do not blur lightly; a solid box is safe.

| # | File | What to capture |
|---|---|---|
| 01 | `01-architecture-diagram.png` | The Mermaid diagram rendered on GitHub (README) |
| 02 | `02-ci-pipeline-green.png` | `deployflow-ci` run with both stages green and the test count |
| 03 | `03-trivy-gate-failure.png` | Scenario 2: the Trivy step failing and BuildPush not run |
| 04 | `04-cd-approval.png` | `deployflow-cd` waiting for production approval with staging green |
| 05 | `05-canary-step-log.png` | Log lines of a canary step (probe counts, p95, "Step 1 passed") |
| 06 | `06-auto-rollback-log.png` | Scenario 3: breach warning and `OUTCOME: rolled_back` |
| 07 | `07-revisions-traffic-split.png` | Portal > Container App > Revisions showing a traffic split |
| 08 | `08-dashboard-overview.png` | Dashboard top: both environment cards and KPIs |
| 09 | `09-dashboard-security-verified.png` | Security panel with Verified for both environments |
| 10 | `10-dashboard-deployment-history.png` | Deployment history with outcomes and incidents |
| 11 | `11-dashboard-slo-alerts.png` | SLO cards and the alerts table |
| 12 | `12-dashboard-cost-resources.png` | Cost panel with its notice, plus the Resources table |
| 13 | `13-alert-email.png` | An alert email (hide your address) |
| 14 | `14-terraform-plan-no-changes.png` | Infrastructure pipeline plan summary "0 to add, 0 to change, 0 to destroy" |
| 15 | `15-infra-approval-gate.png` | The `infrastructure` environment waiting for approval with the plan artifact |
| 16 | `16-iam-least-privilege.png` | IAM role assignments for the dashboard identity (Reader, Log Analytics Reader, AcrPull) |
| 17 | `17-teardown-preview-refused.png` | `teardown.ps1 -Stack prod` or `shared` refusing |

README uses 02, 03, 04, 05, 06, 08, 09, 12 and 15. Add the others to the README if you like, or delete rows you did not capture.