## Why

The `agentic-ai-enterprise-blueprint` project generates Azure infrastructure assuming a
greenfield, single-subscription deployment. Real customer subscriptions rarely match that
assumption — existing VNets/subnets, cross-subscription networking, and management-group-level
policy constraints are common but invisible to the blueprint today. A written requirements doc
from a customer is typically too sparse to capture these constraints; the subscription itself is
the only reliable source. We need a read-only discovery script that queries a subscription and
its parent management group (where visible) and emits a single structured JSON artifact
describing what exists and what's constrained, so that Bicep parametrization decisions can be
made with real information instead of assumptions.

## What Changes

- Add a read-only CLI script that discovers, for one or more target subscriptions: resource
  groups, VNets/subnets/peerings (with subscription ID on each), effective policy (via
  `az policy state list`, not just `az policy assignment list`, per the grounding notes in
  `design.md`), observed naming patterns, and a reserved placeholder for quota data.
- Emit a single structured JSON document per the schema defined in `design.md`, with independent
  best-effort sections so a failure in one (e.g. no management-group access) does not block the
  others.
- Accept one or more subscription IDs (default: current `az account show` subscription) and an
  optional management group ID as inputs.
- The script does not modify the blueprint's Bicep modules and performs no write operations
  against Azure.

## Capabilities

### New Capabilities
- `subscription-discovery`: read-only discovery of an Azure subscription's existing resources,
  networking topology, effective policy constraints, and observed naming conventions, emitted as a
  single structured JSON artifact for downstream review.

### Modified Capabilities
(none — no existing baseline specs)

## Impact

- New script/tooling added to the repo (no existing code affected — repo is currently empty
  aside from OpenSpec scaffolding).
- Depends on Azure CLI (`az`) being installed and authenticated; requires Reader on target
  subscription(s).
- No changes to deployed Azure resources; read-only against subscription/management-group APIs.
- Output JSON becomes an input to future (separate, out-of-scope) work that parametrizes the
  blueprint's Bicep modules.
