# ADR 0005: Progressive delivery and automatic rollback

## Status
Accepted

## Context
Releasing straight to 100% of production traffic means a bad release hurts everyone before anyone notices. Azure Container Apps revisions and traffic splitting allow a safer path.

## Decision
- Production runs in multiple-revision mode. Each release creates a new revision that starts with 0% of the traffic.
- Before any user traffic, the candidate is smoke tested on its own revision URL.
- Traffic then shifts in steps (10%, 50%, 100%). After each step the pipeline probes the live URL and the candidate directly and compares the error rate and the 95th percentile latency with limits.
- Any breach restores 100% of the traffic to the last known-good revision (the revision that held 100% before the release) and deactivates the candidate. Rollback uses `az containerapp ingress traffic set`, which is idempotent.
- The previous revision stays active after a successful release so a manual rollback is one pipeline run (`deployflow-rollback`).
- Every outcome is written to a record (outcome, per-step measurements, revisions) and stored as a pipeline artifact.
- Terraform ignores the image, release-time environment variables and traffic weights, so infrastructure and releases do not fight.
- A demo-only fault switch (`FAULT_INJECTION_PERCENT`, default 0, only affects `/`) lets the team prove on demand that rollback works.

## Limitations of health-based rollback
- The probes are synthetic. They catch crashes, errors and slowness, not subtle logic or data bugs.
- With little real traffic, a few probes give noisy statistics. The limits tolerate one transient error in 30 probes.
- Probes run from one place (the build agent), so they do not see regional problems.
- Rolling back code does not roll back data. See the migration strategy below.
- A rollback needs the previous revision to still exist. We keep it active after every successful release.
- Scale-from-zero adds latency to the first requests, so the pipeline warms revisions up before measuring.

## Database migrations and other irreversible changes
The app has no database today. When one is added:
- Use expand/contract migrations: first add new columns or tables in a backward-compatible way (expand), release code that works with both old and new shapes, and only remove old structures (contract) in a later release.
- Never ship a migration that makes the previous revision fail, because the previous revision must remain a safe rollback target.
- Take a backup or snapshot before a migration, and write a tested down-migration for anything that can be reversed.
- For changes that cannot be reversed, prefer roll forward with a fix over roll back, and use feature flags to turn behaviour off without a rollback.

## Consequences
- A bad release usually affects only the canary share of traffic for about a minute.
- Release pipelines take longer (several minutes) because of the observation windows.
- The pipeline identity can change traffic, so the production approval and branch check remain the main protection.