## Context

See `proposal.md` - Why. Both `scripts/discover-subscription.sh` and
`scripts/discover-subscription.ps1` already compute `RELEVANT_DENY_MODIFY_JSON` /
`$RelevantDenyModify` (a filtered list of compliance tuples: `assignmentName`, `definitionName`,
`scope`, `effect`, `subscriptionId`) and separately collect raw `assignmentsVisible` from
`az policy assignment list`. This change adds a lookup step after the shortlist is computed,
without changing how the shortlist itself is derived.

## Goals / Non-Goals

**Goals:**
- Resolve one policy definition detail record per distinct `definitionName` in the Deny/Modify
  shortlist, via `az policy definition show --name <name>` (or `--id` for definitions expressed
  as a full resource ID).
- Attach matching assignment detail (already-available fields from `assignmentsVisible`) to each
  shortlist entry, keyed by `assignmentName`.
- Keep both scripts (bash+jq, PowerShell) behaviorally identical, as established in the base
  change.

**Non-Goals:**
- Resolving definitions for policies outside the Deny/Modify shortlist (e.g. pure `Audit`
  effects) - explicitly out of scope per the proposal.
- Deduplicating or merging assignment detail across scopes beyond a simple name match - if two
  different assignments share an `assignmentName` (unusual but possible across scopes), the
  first match found is used.
- Resolving custom policy definitions defined at a scope the caller cannot read - reported as an
  `error` entry instead.

## Decisions

- **Definition lookup keyed by name, deduplicated first**: Build the distinct set of
  `definitionName` values from the shortlist before issuing any `az policy definition show`
  calls, so a definition referenced by multiple shortlist entries (e.g. assigned at several
  scopes) is only looked up once. Alternative considered: look up per shortlist entry
  (simpler code, but duplicate `az` calls for common built-ins like `Deny-Public-IP`); rejected
  for the wasted calls.
- **`az policy definition show --name` first, `--management-group`/`--subscription` fallback
  only if needed**: Built-in definitions resolve by name alone. Custom definitions may require a
  scope hint. Following the existing pattern in this repo (per-RG VNet fallback), try the
  simplest call first and only add scope flags if the bare call fails structurally (not just
  access-denied, since access-denied should surface as the per-definition `error` rather than
  trigger scope-guessing that could itself fail loudly).
- **Best-effort per definition, not all-or-nothing**: Each `az policy definition show` call is
  wrapped the same way other optional sections are (see `run_az_json` / `Invoke-AzJson`) - on
  failure, emit `{ name, error }` for that one entry and continue, consistent with the existing
  "independent, best-effort sections" requirement already governing this script.
- **Assignment detail via lookup table, not re-querying**: `assignmentsVisible` is already
  collected earlier in the same run; build a name→record lookup (bash: `jq` `INDEX(.name)` or a
  scratch-file map; PowerShell: a hashtable keyed by `.name`) rather than issuing new `az`
  calls, since the data is already present and re-querying would be redundant and slower.
- **New top-level array `policy.definitionsDetail`, plus `assignmentDetail` inline on shortlist
  entries**: keeps the shortlist entries self-contained (a reviewer reading one entry sees both
  its assignment and, via `definitionName`, can cross-reference the definition), while avoiding
  duplicating the (potentially large) `policyRule`/`parameters` schema data once per shortlist
  entry when the same definition appears multiple times.
- **Simplified constraint summary via generic `policyRule.if` tree walk, not per-policy special
  casing**: Rather than hand-writing extraction logic per known built-in policy, recursively walk
  the `policyRule.if` (and nested `allOf`/`anyOf`/`not`) structure looking for any object that has
  a `field` key. For each such condition object, capture `{ field, operator, value }` where
  `operator` is whichever comparison key is present (`equals`, `notEquals`, `in`, `notIn`,
  `like`, `notLike`, `match`, `contains`, `exists`, ...) and `value` is that key's raw value
  (including unresolved `[parameters('x')]` references — these are not evaluated, just passed
  through as-is since resolving them would require simulating assignment-time parameter binding).
  Classify each captured condition into a bucket by matching `field` (case-insensitive) against:
  - `type` → `resourceTypesAffected` (collect the `value`, not the condition object, since the
    field itself is constant)
  - `name` (exact) → `namingRules`
  - `resourceGroup`, `resourceGroup.name`, `resourceGroupName` → `resourceGroupRules`
  - `location` → `locationRules`
  - starts with `tags` (`tags`, `tags[...]`, `tags.*`) → `tagRules`
  - starts with `Microsoft.Network/` or contains `subnet`/`vnet`/`virtualnetwork`/
    `networksecuritygroup`/`publicip` (case-insensitive) → `networkRules`
  - anything else is not bucketed (omitted from the simplified summary; still present in the
    raw `policyRule` for anyone who needs it)
  Alternative considered: parse each known built-in policy's semantics individually (e.g.
  special-case "Allowed locations", "Require a tag"); rejected because it doesn't generalize to
  custom policies and would need constant maintenance as new built-ins appear.
- **Best-effort, not a policy evaluator**: This is explicitly a heuristic summary for human
  reviewers, not a policy engine. Nested boolean combinators are flattened (a condition found
  under a `not` is still bucketed the same way, without inverting its meaning) - the design
  favors "surface everything that might matter, labeled by category" over "precisely model
  policy semantics", which would be a much larger undertaking. This trade-off is called out
  explicitly in the proposal and spec so consumers don't over-trust the summary.

## Risks / Trade-offs

- [Custom policy definitions may need an explicit `--management-group`/`--subscription` scope
  to resolve by name, and the correct scope isn't always inferable from the compliance tuple
  alone] → Mitigation: try subscription scope first (matches the tuple's `subscriptionId`), and
  if `az policy definition show` fails, retry once with `--management-group` when a
  `--management-group` was supplied to the script; otherwise report as unresolved with `error`.
- [`policyRule` and `parameters` payloads can be large for complex custom policies, increasing
  output size] → Mitigation: acceptable per proposal (explicitly requested); deduplication by
  definition name (not by shortlist entry) already minimizes repeated payload.
- [Azure CLI output field names for `az policy definition show` may vary slightly by CLI
  version, similar to the `PolicyAssignmentName`/`policyAssignmentName` casing issue already
  handled for compliance state] → Mitigation: apply the same `//` fallback-chain pattern used
  elsewhere in the bash script (jq) and case-insensitive property lookup in PowerShell.

## Open Questions

None - scope and field set were confirmed directly with the user (proposal.md).
