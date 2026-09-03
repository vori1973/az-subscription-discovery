## Why

Even with full policy definitions and effective networking topology in the discovery output
(base capability, plus the `expand-policy-definitions` change), an architect still has to
manually cross-reference several sections — which VNet is the hub, what its address space is,
what resource-group naming pattern is actually observed, and which tag keys are actually
enforced — before they can start parametrizing new infrastructure for the subscription. This
change synthesizes those cross-section facts into one small, human-readable block so that
common "what do I need to know before I design this" questions are answered directly by the
discovery output.

## What Changes

- Add a new `architectureConstraints` top-level output section that synthesizes facts already
  present elsewhere in the output (networking, naming, policy) into one place:
  - `networkResourceGroup`: best-effort identification of the resource group hosting the
    subscription's "hub"/shared networking resources.
  - `resourceGroupNaming`: the observed resource group naming pattern (surfaced from the
    existing `namingObserved.resourceGroups` summary).
  - `requiredTags`: distinct tag keys enforced by Deny/Modify/Append policies (derived from the
    `expand-policy-definitions` output's per-definition `tagRules` bucket).
  - `vnetAddressSpace`: address space of the identified hub VNet (if one is identified).
  - `hubPeering`: name of the VNet identified as the hub, based on peering topology (the VNet
    that the largest number of other VNets peer with).
- All fields in this section are explicitly labeled best-effort/heuristic, consistent with the
  existing "observed naming convention" framing already used elsewhere in this output — none of
  them are treated as authoritative or guaranteed-correct.
- This change depends on `expand-policy-definitions` being implemented first (it consumes that
  change's per-definition `tagRules` output for `requiredTags`); sequencing only, no spec-level
  coupling beyond that.

## Capabilities

### New Capabilities
- `architecture-constraint-synthesis`: derives a small set of cross-section, best-effort
  architecture facts (hub VNet identification, its address space, observed resource-group
  naming, and policy-enforced tag keys) from data already collected by the other discovery
  capabilities.

### Modified Capabilities
- `subscription-discovery`: the "Structured JSON output" requirement's list of top-level output
  sections is extended to include the new `architectureConstraints` section.

## Impact

- `scripts/discover-subscription.sh` and `scripts/discover-subscription.ps1`: add a synthesis
  step after networking, policy, and naming sections are all computed (this section reads from
  all three, so it must run last).
- Output schema: additive top-level `architectureConstraints` section; no existing fields change
  shape (non-breaking).
- `scripts/README.md`: document the new section and its heuristic/best-effort nature.
