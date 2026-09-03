## 1. Hub identification (bash)

- [ ] 1.1 Compute per-VNet peering counts from `networking.vnets[].peerings` (already
      assembled) and select the VNet with the strictly highest count as the hub; on a tie
      (including zero peerings for all VNets) leave the hub unidentified
- [ ] 1.2 Derive `hubPeering` (hub VNet name) and `networkResourceGroup` (hub VNet's resource
      group) from the identified hub, or `null`/`null` if unidentified
- [ ] 1.3 Derive `vnetAddressSpace` by looking up the identified hub VNet's `addressSpace` in
      `networking.vnets`, or `null` if unidentified

## 2. Naming and tag surfacing (bash)

- [ ] 2.1 Surface `resourceGroupNaming` as a direct pass-through of
      `namingObserved.resourceGroups`
- [ ] 2.2 Build `requiredTags` by extracting tag keys from every resolved policy definition's
      `tagRules` bucket (from `expand-policy-definitions`) across the Deny/Modify shortlist,
      deduplicated; empty array if none found
      (depends on `expand-policy-definitions` tasks 1-3 being implemented first)

## 3. Assemble section (bash)

- [ ] 3.1 Assemble `ARCHITECTURE_CONSTRAINTS_JSON` = `{ networkResourceGroup, resourceGroupNaming,
      requiredTags, vnetAddressSpace, hubPeering }` after networking, policy, and naming
      sections are computed
- [ ] 3.2 Add `architectureConstraints` to the final output JSON

## 4. Mirror in PowerShell

- [ ] 4.1 Port task group 1 (hub identification) to `discover-subscription.ps1`
- [ ] 4.2 Port task group 2 (naming/tag surfacing)
- [ ] 4.3 Port task group 3 (section assembly), applying the same array-unwrapping precautions
      already established in this script for `requiredTags` (an array field)

## 5. Verification

- [ ] 5.1 Run both scripts against the live test subscription; confirm `architectureConstraints`
      is populated and matches between bash and PowerShell (modulo array ordering)
- [ ] 5.2 Verify hub identification against the known topology (manually confirm which VNet has
      the most peerings in the test subscription) and that ties/no-peerings correctly yield
      `null` rather than an arbitrary pick (test with a temporarily-filtered peerings list if
      the live subscription doesn't naturally have a tie case)
- [ ] 5.3 Verify `requiredTags` is a JSON array even when exactly one tag key is found (PowerShell
      single-element array serialization check, consistent with the `addressSpace` bug fixed
      earlier in this script)
- [ ] 5.4 Update `scripts/README.md` to document the new `architectureConstraints` section and
      its heuristic/best-effort nature
- [ ] 5.5 Mark all tasks in this file complete and run `openspec validate
      derive-architecture-constraints --strict`
