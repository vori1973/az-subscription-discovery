## Why

The discovery script currently answers "what exists in this subscription?" but not "what can I
deploy here, and what will block me?" Per the Azure Subscription Discovery Framework v2 proposal
(Phase 1), reviewers evaluating a subscription for new platform workloads (e.g. Azure AI Foundry,
API Management) also need to see RBAC assignments, whether required resource providers are
registered, existing private endpoints and private DNS zones, and actual subscription/network
quota usage — today these require several manual `az` calls the script doesn't surface. Phase 1
of the v2 proposal adds exactly these five read-only discovery areas; later phases (NSGs/route
tables/hybrid connectivity/landing zones, and deployment-readiness scoring) are deferred to
follow-up changes.

## What Changes

- Add RBAC discovery: role assignments (`az role assignment list --all`) and custom role
  definitions (`az role definition list --custom-role-only`), summarized per-principal.
- Add resource provider registration discovery (`az provider list`), reporting registration state
  for a fixed priority list of providers relevant to common platform workloads (Cognitive
  Services, API Management, Search, Container Service, Key Vault, Web, Network, Operational
  Insights).
- Add Private Endpoint discovery (`az network private-endpoint list`), reporting name, resource
  group, subnet, and the private-link connection's target resource and grouping status.
- Add Private DNS discovery: zones (`az network private-dns zone list`) and their VNet links
  (`az network private-dns link vnet list`), reporting which VNets are linked to which zones.
- Replace the previously placeholder `quotas` section with real subscription quota/usage data:
  compute usage (`az vm list-usage`) and network usage (`az network list-usages`), scoped per
  region already observed in the subscription's discovered VNets (falling back to the
  subscription's default location when no VNets exist).
- Port all of the above to both `discover-subscription.sh` and `discover-subscription.ps1`,
  producing identical JSON output, consistent with every prior discovery capability in this repo.
- Each new section remains independent and best-effort: a failure or access denial in one (e.g.
  no `Microsoft.Authorization/roleAssignments/read` at subscription scope) SHALL NOT prevent any
  other section — existing or new — from being gathered and reported.

## Capabilities

### New Capabilities
- `platform-readiness-discovery`: RBAC assignments/custom roles, resource provider registration
  status, private endpoint discovery, private DNS zone/link discovery, and populated
  subscription/network quota usage — all read-only, independently-reported discovery sections
  that inform whether a subscription is ready to host a new platform workload.

### Modified Capabilities
- `subscription-discovery`: the "Structured JSON output" requirement's top-level section list
  gains `rbac`, `providers`, `privateEndpoints`, and `privateDns`, and `quotas` is no longer
  described as a placeholder — it now contains real compute/network usage data (see
  `platform-readiness-discovery`).

## Impact

- `scripts/discover-subscription.sh` and `scripts/discover-subscription.ps1`: new discovery
  sections and their assembly into the final JSON output.
- `scripts/README.md`: documentation for the new `rbac`, `providers`, `privateEndpoints`,
  `privateDns`, and populated `quotas` sections.
- No breaking changes to existing output fields; this only adds new top-level sections and
  populates the previously-empty `quotas` placeholder.
- Requires `Reader` role at subscription scope (already required); no new Azure permissions are
  needed since all calls are read-only `list`/`show` operations available to `Reader`.
