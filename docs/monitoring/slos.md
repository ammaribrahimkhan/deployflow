# Service level indicators (SLIs) and objectives (SLOs)

## The three SLOs

| # | SLI (what we measure) | Where it comes from | SLO (target) | Window |
|---|---|---|---|---|
| 1 | Availability: share of availability test runs that succeed | Application Insights availability test on `/health` (production) | 99.5% | 30 days |
| 2 | Request success: share of user requests that do not fail with a 5xx status (the `/health` endpoint is excluded) | Container app request logs in Log Analytics | 99.0% | 30 days |
| 3 | Latency: share of user requests handled in under 500 ms (server-side) | Container app request logs in Log Analytics | 95.0% | 30 days |

## Error budget

- The error budget is what the SLO still allows. For SLO 2 (99%), 1 in every 100 requests may fail.
- `monitoring/queries/04-slo-and-error-budget.kql` shows the SLIs, the error budget in requests, and how much of it is used.
- Policy: when more than 100% of the monthly budget is used, stop non-essential releases until it recovers, and fix reliability first. When more than 50% is used in the first half of the month, review recent releases.

## How to measure

```powershell
.\scripts\run-kql.ps1 -QueryFile .\monitoring\queries\04-slo-and-error-budget.kql -AppName ca-deployflow-prod -Hours 720
```

## Limits (be honest in an interview)

- This is a low-traffic demo app: with very few requests, percentages are noisy and one failed request moves the numbers a lot.
- The latency SLI is measured inside the app. It does not include network time between the user and Azure. The availability test and Azure's `ResponseTime` metric give an outside view.
- Synthetic traffic from the pipeline and from `generate-traffic.ps1` is counted like real traffic, so avoid running load tests against production without noting it.
- The free-tier setup has no redundancy (one region, one shared environment), so 99.5% is a realistic target, not 99.99%.