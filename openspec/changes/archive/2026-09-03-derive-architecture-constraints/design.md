## Context

See `proposal.md` - Why. This change runs after networking (VNets/subnets/peerings), naming
(`namingObserved`), and policy (specifically the `expand-policy-definitions` change's per-
definition `tagRules`) are all computed, since it synthesizes facts from all three. It has a
sequencing dependency on `expand-policy-definitions` being implemented first, for `requiredTags`.

## Goals / Non-Goals

**Goals:**
- Answer, without manual cross-referencing, "which VNet is the hub, what's its address space,
  what RG naming pattern is observed, and what tags does policy actually enforce" directly from
  the discovery output.
- Keep every field explicitly best-effort/heuristic, consistent with the existing
  `namingObserved` framing (observed, not authoritative).

**Non-Goals:**
- Simulating full Azure Policy evaluation (scope matching, exemptions, parameter binding) to
  determine with certainty which tags are enforced on which resource types - `requiredTags` is
  a simple "referenced anywhere in a Deny/Modify/Append condition" extraction, not a compliance
  guarantee.
- Handling multi-hub or hub-and-spoke-of-hubs topologies with high confidence - if the topology
  is ambiguous (tie in peering count, or no peerings), the design explicitly reports `null`
  rather than guessing.
- Identifying a hub VNet across subscriptions when only one subscription is targeted - hub
  identification only considers VNets already present in this run's `networking.vnets`.

## Decisions

- **Hub identification via peering count, not naming heuristics**: Count each VNet's number of
  entries in `networking.vnets[].peerings` (already discovered) and pick the VNet with the
  strictly highest count as the hub. Alternative considered: match VNet names against patterns
  like `hub`/`connectivity`/`shared` (similar to the Deny/Modify shortlist's name-pattern
  matching); rejected as a primary signal because naming conventions vary too much across
  organizations, but the topology-based peering count is a much stronger, less
  convention-dependent signal. On a tie (including a 0-way tie, i.e. no peerings at all),
  report `null` rather than picking arbitrarily.
- **`requiredTags` sourced from `tagRules`, not re-parsing `policyRule`**: Reuse the
  `tagRules` bucket already produced by `expand-policy-definitions` (one bucket per resolved
  definition) rather than independently re-scanning `policyRule`, to avoid duplicating that
  parsing logic. Extract just the tag *key* from each bucketed condition's `field` value (e.g.
  `field: "tags['Environment']"` → key `Environment`), deduplicated across all resolved
  definitions from the Deny/Modify shortlist. This is why this change has a sequencing
  dependency on `expand-policy-definitions`.
- **`resourceGroupNaming` is a direct pass-through, not a re-derivation**: `namingObserved.
  resourceGroups` already computes common prefixes; `architectureConstraints.
  resourceGroupNaming` simply surfaces that same value under a name that's easier to find
  without knowing the full naming-section shape. No new naming-detection logic is introduced.
- **Section computed last, after networking/policy/naming are assembled**: Unlike the other
  sections (independent, best-effort per the base capability's requirement), this section
  explicitly depends on the others already being computed in the same run - it is purely a
  read/summarize step over already-collected in-memory data, issuing no new `az` calls itself.

## Risks / Trade-offs

- [Peering-count-based hub detection can be wrong for non-hub-and-spoke topologies (e.g. full
  mesh, or a hub with equal peering count to a large spoke)] → Mitigation: ties resolve to
  `null` rather than an incorrect guess; the field is explicitly documented as heuristic in the
  spec so consumers know to verify it.
- [`requiredTags` extraction depends entirely on how well `expand-policy-definitions`'s generic
  field-bucketing captures tag-related conditions - a policy that expresses tag requirements in
  an unusual way (e.g. via a `field: "tags"` count/`exists` check rather than a specific key)
  may not surface a specific tag key] → Mitigation: acceptable given both changes are explicitly
  scoped as best-effort; not a regression since no such summary exists today.
- [Sequencing dependency on `expand-policy-definitions` means this change cannot be usefully
  applied until that one is implemented] → Mitigation: this is a planning-time constraint only,
  not a runtime one; `openspec apply` for this change can still be started once
  `expand-policy-definitions` tasks are complete, and the `requiredTags` task explicitly notes
  the dependency in tasks.md.

## Open Questions

None currently — hub-identification tie-breaking (`null`) and the `requiredTags` source
(`tagRules` reuse) were decided above rather than left open.
