# ADR 0002: One shared Container Apps environment

## Status
Accepted

## Context
The Azure free subscription allows only one Container Apps environment. Creating a second one failed with `MaxNumberOfGlobalEnvironmentsInSubExceeded`.

## Decision
Terraform creates a single environment, `cae-deployflow-shared-eus2`, in the shared stack. Dev, staging and production are separate Container Apps inside it. Each has its own resource group, managed identity, Application Insights instance and Terraform state file.

## Consequences
- Environments are isolated by resource group, identity and RBAC, but they share compute infrastructure and the network boundary of the environment.
- A production system would normally use a separate environment (or subscription) per stage. That is a documented limitation of this free-tier project, not a design preference.
- Container Apps revisions still give each app its own safe release path (traffic splitting and rollback in Milestone 6).
- The earlier manual sandbox environment was deleted so Terraform could own the only slot.