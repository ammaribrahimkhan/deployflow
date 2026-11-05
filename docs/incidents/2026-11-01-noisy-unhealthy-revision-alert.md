# Incident report: repeated Sev1 "unhealthy revision" alerts during releases

Status: **mitigated, verification pending** (see action item 1)
Severity: low (alert noise, no user impact)
Type: monitoring defect (false positives)
Times below are as shown in the dashboard (browser time zone).

## Summary

Between 10/31 4:45 PM and 11/1 8:25 PM the `unhealthy-revision` alert fired **22 times in about 28 hours** (9 times for production at Sev1, 13 for staging at Sev3). The firings clustered around releases, canary rejections and rollbacks. The apps were healthy: the availability test showed 100% (161 of 161) when the data was captured. The rule counted a few normal probe failures as a problem.

## Impact

- 22 alert notifications, 9 of them Sev1, each lasting roughly 20 to 50 minutes before auto-resolving.
- Risk: real alerts would be ignored.
- No user impact. No data loss.

## Timeline (production, taken from the dashboard)

| Time | Deployment history | Alert |
|---|---|---|
| 10/31 6:50 PM | Canary rejected and recovered (6:50 PM) | Fired 6:50 PM, cleared 7:11 PM |
| 10/31 7:30 PM | Canary rejected and recovered (7:25 PM) | Fired 7:30 PM, cleared 7:51 PM |
| 10/31 8:35 PM | Promoted (8:26 PM), manual rollback (8:31 PM) | Fired 8:35 PM, cleared 8:56 PM |
| 11/1 12:30 AM | Canary rejected and recovered (12:29 AM) | Fired 12:30 AM, cleared 12:51 AM |
| 11/1 4:30 AM | Promoted (4:20 AM), manual rollback (4:28 AM) | Fired 4:30 AM, cleared 4:51 AM |
| 11/1 5:00 PM | Promoted (4:52 PM), rollback with no action (5:18 PM) | Fired 5:00 PM, cleared 5:26 PM |
| 11/1 7:25 PM | Promoted (7:13 PM), manual rollback (7:18 PM) | Fired 7:25 PM, cleared 8:16 PM |
| 11/1 8:25 PM | (no new release) | Fired 8:25 PM, cleared 9:01 PM |

Every firing that can be matched to the deployment history follows a release or rollback within minutes.

## Detection

The alert emails themselves. Reviewing them next to the dashboard's deployment history showed the pattern.

## Root cause

The rule counted failed health probes, crash back-offs and image-pull problems together and fired at 3 events in 10 minutes. Azure Container Apps emits a few failed probes whenever a revision starts, stops or is deactivated, which is exactly what a progressive release, a canary rejection or a rollback does. The threshold was designed for crash loops, not for normal revision turnover.

## Resolution

The alert query was updated to separate probe failures from crash and image-pull problems:

- **Probe failures:** 12 or more events in 10 minutes (`probe_failure_threshold`).
- **Crash back-offs and image-pull problems:** 3 or more events in 10 minutes (`unhealthy_events_threshold`).

This prevents temporary health-probe failures during normal revision starts, stops, releases and rollbacks from triggering the same alert threshold as persistent crash or image-pull failures.

The change was introduced in commit `ea166ee` on 1 November 2026 at 21:18:34 PKT. It modified `infra/modules/alerts/main.tf` and `infra/modules/alerts/variables.tf`.

The change was applied through Terraform. Verification through a normal release is still pending.

## What went well / what did not

- Went well: the alert data, deployment events and dashboard made the pattern obvious in minutes. The fix was a small, reviewed Terraform change.
- Did not: the rule was never tested against a normal release before it paged at Sev1. Thresholds were guessed instead of measured.

## Action items

| # | Action | Status |
|---|---|---|
| 1 | Run a normal release (demo scenario 1) and confirm **no** unhealthy-revision alert fires. Update this report with the result | Open |
| 2 | Keep demo scenario 1 as the regression check for alert noise after any alert change | Open |
| 3 | Document why the thresholds differ in `docs/monitoring/alerts.md` | Done |
| 4 | Consider making this rule a lower severity (ticket) and paging only on error rate, availability and restarts | Open |

## Lessons

- An alert must be tested against normal operations (releases, rollbacks, scale from zero), not only against failures.
- Separate signals that mean different things; do not share one threshold.
- Alert on symptoms that users feel before causes that Azure explains in logs.

## Facts to confirm before you publish this report

Run these and correct the report if they disagree:

```powershell
git log --oneline --date=iso --format="%h %ad %s" -- infra/modules/alerts
```

- The commit that introduced `probe_failure_threshold` and when it was applied.
- Whether the 11/2 2:50 PM staging alert came from your own broken-image test.