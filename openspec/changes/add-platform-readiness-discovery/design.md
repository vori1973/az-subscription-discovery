## Context

Both scripts already follow a consistent internal shape: numbered sections (1. Resource groups,
2. Networking, 3. Policy, 4. Naming, 5. Architecture constraints, 6. Assemble output), each
independent and best-effort. Bash wraps every Azure CLI call through a shared `run_az_json`
helper that returns success/failure and lets the caller fall back to an empty result (`[]`)
without aborting the script; PowerShell has an equivalent try/catch wrapper used the same way in
the policy and networking sections. See proposal.md for motivation and
`specs/platform-readiness-discovery/spec.md` for the full requirements this design implements.

## Goals / Non-Goals

**Goals:**
- Add five new best-effort discovery sections (RBAC, providers, private endpoints, private DNS,
  quotas) using the same independent-section, best-effort pattern already used throughout both
  scripts.
- Keep bash and PowerShell output byte-for-byte structurally identical, as already verified for
  every prior section.
- Populate the previously placeholder `quotas` section with real per-region usage data.

**Non-Goals:**
- Phase 2 (NSGs, route tables, hybrid connectivity, landing zone discovery) and Phase 3
  (deployment-readiness scoring for Foundry/OpenAI/Search/APIM/AKS) from the v2 proposal — these
  are deferred to separate follow-up changes.
- Any write/remediation action based on discovered gaps (e.g. auto-registering an unregistered
  provider) — this remains a read-only discovery tool.
- Cross-referencing RBAC assignments against policy or network data (e.g. "who can modify this
  subnet") — only raw assignment/definition listing is in scope.

## Decisions

- **New section insertion point**: insert the five new sections as "4. Platform readiness
  discovery" (RBAC, providers, private endpoints, private DNS, quotas) immediately after the
  existing "3. Policy" section and before the current "4. Observed naming conventions", which
  renumbers to "5.", "6. Architecture constraint synthesis" to "7.", and "7. Assemble output" (bash)
  / "6. Assemble output" (ps1, currently "6.") to the new final number. Rationale: keeps the
  existing numeric ordering meaningful (topology/access data before naming/synthesis, which is
  already derived-from-earlier-sections) rather than appending everything at the end.
- **RBAC data model**: report `assignments` as a flat list (principalId, principalType,
  roleDefinitionName, scope, subscriptionId) rather than nesting by principal, and compute
  `ownershipSummary` as a simple map of role name → assignment count. Rationale: a flat list is
  the least lossy representation and matches the raw `az role assignment list` shape most
  closely; the summary is explicitly a convenience view, not the source of truth. Alternative
  considered: nesting by principal first — rejected because a principal can appear at many scopes
  and nesting would obscure scope, which is the field reviewers care about most for readiness
  checks.
- **Provider priority list is fixed, not fully enumerated**: `az provider list` returns 200+
  providers; reporting only a curated priority list (matching the proposal's list exactly) keeps
  output focused on providers relevant to common platform workloads. Rationale: an exhaustive dump
  adds noise without adding signal for this tool's stated purpose. Alternative considered: report
  all providers — rejected as out of scope for "deployment readiness" framing; can be revisited if
  a future consumer needs the full list.
- **Quota regions derived from discovered VNets, not hardcoded**: reuse the region values already
  present in the `networking.vnets` section (deduplicated) as the region list for both
  `az vm list-usage --location` and `az network list-usages --location`, falling back to the
  subscription's default location (`az account show --query 'items[0].location'`-equivalent,
  i.e. whatever location metadata is already gathered in the `meta` section) when no VNets exist.
  Rationale: avoids hardcoding a region list (the original proposal's example hardcodes
  `eastus`/`eastus2`, which would silently miss other regions or report irrelevant ones) and
  keeps quota data scoped to where the subscription actually has infrastructure.
- **Best-effort per-region, not all-or-nothing**: quota/usage listing failures are scoped to the
  individual region that failed (matching the existing per-subscription best-effort pattern in
  the policy section), so one inaccessible region doesn't blank out quota data for regions that
  do succeed.
- **New capability vs. modifying `subscription-discovery`**: RBAC/providers/private
  endpoints/private DNS/quotas become a new `platform-readiness-discovery` capability (distinct
  concern: "is this ready for a new workload" vs. "what exists"), while the `subscription-discovery`
  capability only needs a MODIFIED requirement to its output-schema description — matching the
  precedent set by `expand-policy-definitions` and `architecture-constraint-synthesis` in this
  repo's change history.

## Risks / Trade-offs

- [Provider priority list becomes stale as new platform services emerge] → keep the list a simple
  data array in the script (not derived from anything dynamic) so it's a one-line diff to extend
  in a future change; document the list in `scripts/README.md` so it's easy to find.
- [Quota API calls add latency per discovered region] → these are lightweight `list-usage`/
  `list-usages` calls (no pagination expected at typical region counts); acceptable given the
  existing script already issues many per-subscription/per-VNet calls.
- [RBAC listing can return a very large `assignments` array in large subscriptions] → no
  server-side filtering is applied (matches the existing "report everything, no pagination/limit"
  precedent elsewhere in the script); acceptable since the tool is meant for point-in-time human
  review, not high-frequency automation.
