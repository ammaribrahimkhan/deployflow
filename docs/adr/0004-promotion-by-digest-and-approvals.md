# ADR 0004: Promotion by digest, separate CD pipeline, approvals on production

## Status
Accepted

## Context
The spec requires that the image verified in staging is the image that reaches production, with no rebuild, and that production releases need a manual approval.

## Decision
- CI builds, scans and pushes the image once, and records its digest in `release-metadata.json`.
- A separate CD pipeline (`deployflow-cd`) is triggered by the successful `BuildPush` stage of CI. It never builds.
- Images are deployed by digest (`registry/repo@sha256:...`), not by tag, so staging and production run identical bits.
- The production stage compares the digest with the staging promotion record and refuses any mismatch.
- Approval and a branch check (`main` only) are configured on the Azure DevOps environment `production`.
- Terraform creates the apps and ignores later image changes, so infrastructure and application deployment stay separate.
- Every deployment writes a promotion record (previous revision, new revision, digest, run URLs) as a pipeline artifact. Milestone 6 uses the previous revision for rollback.

## Consequences
- A bad production release is detected by the smoke test but not yet undone automatically. Milestone 6 adds traffic splitting and rollback.
- Staging and production share one Container Apps environment (ADR 0002), so they are isolated by resource group, identity and monitoring, not by network.
- Re-running the pipeline for an already-deployed image is safe: the update is skipped and only the smoke test runs.