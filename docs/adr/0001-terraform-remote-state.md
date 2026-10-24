# ADR 0001: Terraform remote state in Azure Storage

## Status
Accepted

## Context
Terraform needs a place to keep state. Local state files are easy to lose and easy to leak, and they cannot be shared with a pipeline.

## Decision
Store state in an Azure Storage blob container, in a dedicated resource group created by a one-time bootstrap script (Terraform cannot create its own state store).

- Access uses Microsoft Entra ID only: shared-key access is disabled.
- Public blob access is off, HTTPS only, TLS 1.2 minimum.
- Blob versioning and 14-day soft delete allow recovery from mistakes.
- A CanNotDelete lock protects the resource group.
- State locking uses the azurerm backend's blob lease, so two runs cannot change state at once.
- Separate state files per stack (`shared`, `dev`, later `staging` and `prod`) limit blast radius.

## Consequences
- No state or credentials are ever committed to Git.
- We did not add an IP firewall to the storage account: a home internet connection has a changing address, and a wrong rule would lock us out. Entra-only access plus RBAC is the control we rely on.
- The bootstrap script is the only manually run infrastructure; everything else is Terraform.