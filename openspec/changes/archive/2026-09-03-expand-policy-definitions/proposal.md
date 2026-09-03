## Why

The discovery output currently reports policy *assignments* and *compliance state* (assignment
name, definition name, effect, scope) but not the underlying policy *definitions* themselves.
Reviewers can see that a `Deny`/`Modify` policy is in effect but not what it actually enforces
(its display name, description, mode, category, or parameters), which forces a manual lookup in
the Azure portal/CLI for every shortlisted policy before it can be reasoned about.

## What Changes

- Add a policy definition detail lookup (`az policy definition show`) for every distinct
  definition referenced in the existing Deny/Modify shortlist.
- Each resolved definition record includes: `name`, `id`, `displayName`, `description`,
  `policyType` (BuiltIn/Custom/Static), `mode`, `version`, `metadata` (full object, e.g.
  category, version, deprecated flags — not just a single extracted field), `parameters` (the
  parameter schema, not caller-supplied values), `policyRule` (the full effect/if/then logic),
  and `roleDefinitionIds` (roles the policy's managed identity would need, relevant for
  `DeployIfNotExists`/`Modify` policies).
- Additionally, for each Deny/Modify shortlist entry, resolve and attach the matching policy
  *assignment* detail (from `az policy assignment list`, already collected in
  `assignmentsVisible`) by `assignmentName`: `name`, `displayName`, `scope`,
  `policyDefinitionId`, `parameters` (assignment-supplied parameter values), `enforcementMode`,
  `notScopes`, `nonComplianceMessages`, and `identity`. This is only possible when the
  assignment is visible to the caller (see the existing "management-group-inherited policy
  invisible to assignment list" scenario) — if not visible, the assignment detail is omitted
  (definition detail is still reported).
- Add a simplified, architecture-focused summary derived from each resolved definition's
  `policyRule`, for reviewers who need "what does this actually constrain" without reading raw
  policy JSON: `definitionName`, `displayName`, `effect`, `resourceTypesAffected`,
  `namingRules`, `resourceGroupRules`, `locationRules`, `networkRules`, and `tagRules`. Each rule
  bucket is a best-effort heuristic extraction (see design.md) of conditions found anywhere in
  the definition's `policyRule.if` tree that reference the corresponding field category (e.g.
  `field: "name"` → `namingRules`, `field: "location"` → `locationRules`, fields under
  `Microsoft.Network/*` or `tags*` → `networkRules`/`tagRules`). This is best-effort and
  informational, not a guaranteed-complete parse of arbitrary policy logic (nested
  `not`/`anyOf`/`allOf` combinators, `[parameters(...)]` references, and policy functions are
  preserved as raw values rather than fully evaluated).
- Lookups are read-only (`az policy definition show`), independent per definition, and
  best-effort: a definition that cannot be resolved (e.g. inaccessible custom definition scope)
  is reported with an `error` field rather than aborting discovery.
- Definitions referenced only outside the Deny/Modify shortlist (e.g. `Audit`/`AuditIfNotExists`
  effects) are out of scope for this change.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `subscription-discovery`: the effective policy discovery requirement is extended to also
  resolve and report full policy definition details for the Deny/Modify shortlist, in addition
  to the existing assignment/compliance-state/shortlist reporting.

## Impact

- `scripts/discover-subscription.sh` and `scripts/discover-subscription.ps1`: add a definition
  lookup step after the Deny/Modify shortlist is computed; new `az policy definition show` calls
  (one per distinct definition name in the shortlist).
- Output schema: a new `policy.definitionsDetail` array is added (one entry per distinct
  Deny/Modify definition name), each shaped as
  `{ name, id, displayName, description, policyType, mode, version, metadata, parameters,
  policyRule, roleDefinitionIds }` (or `{ name, error }` if resolution fails). Each
  `policy.relevantDenyOrModify` entry additionally gains an `assignmentDetail` field shaped as
  `{ name, displayName, scope, policyDefinitionId, parameters, enforcementMode, notScopes,
  nonComplianceMessages, identity }` when the assignment is visible to the caller, or `null`
  otherwise. Existing fields are unchanged (additive, non-breaking).
- `scripts/README.md`: document the new fields.
