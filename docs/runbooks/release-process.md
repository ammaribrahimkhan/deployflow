# Release process (runbook)

## Normal release

1. Merge a pull request into `main`.
2. `deployflow-ci` runs: scans, tests, builds, scans the image, pushes it, and publishes `release-evidence`.
3. `deployflow-cd` starts by itself:
   - Staging stage: deploys the digest, runs the smoke test.
   - Production stage: waits for approval.
4. Before approving, open the run and check: the staging smoke test passed, and the commit and digest in `promotion-staging` are what you expect.
5. Click Review > Approve. Production then releases progressively:
   - the candidate revision is created with 0% of the traffic and smoke tested on its own URL;
   - 10% of the traffic, then 50%, then 100%, with probes after each step;
   - on success the previous revision stays active for a fast rollback.

## What happens automatically when something is wrong

| Situation | What the pipeline does | User impact |
|---|---|---|
| Candidate fails the pre-traffic smoke test | Deactivates the candidate, stops. Outcome `aborted_before_traffic`. | None |
| A canary step breaches the error-rate or latency limit | Restores 100% of the traffic to the known-good revision, deactivates the candidate, checks health. Outcome `rolled_back`. | Brief, only the canary share |
| Rollback cannot be confirmed | Outcome `rollback_failed`. Run the rollback pipeline immediately. | Possible |
| Traffic is already split by an interrupted release | The next release refuses to start. Run the rollback pipeline first. | Possible |

The outcome and the measurements of every step are in the `promotion-production` artifact (`promotion-production.json`).

## If the staging smoke test fails

- The Production stage is skipped. Nothing reaches production.
- Open the `Smoke test staging` step log. The failure messages say what was wrong.
- Check the staging app logs: Portal > Container Apps > `ca-deployflow-staging` > Monitoring > Log stream.
- Fix forward with a new commit, or rerun the pipeline if the failure was a cold start.

## Manual rollback

Use the `deployflow-rollback` pipeline (Pipelines > deployflow-rollback > Run pipeline). Leave `targetRevision` empty to go back to the previous revision, or enter a revision name. Approve the production environment check. The pipeline restores the revision, verifies the traffic, and smoke tests production. Running it again when the target is already live does nothing.

## Rejecting a release

Click Review > Reject on the production stage. Production is untouched.

## Reading the evidence

- `promotion-staging` and `promotion-production`: records and smoke test results.
- `rollback-record`: who/what/when for a manual rollback.
- Portal > Container Apps > `ca-deployflow-prod` > Revisions and replicas: live view of revisions, traffic split and active/inactive state.