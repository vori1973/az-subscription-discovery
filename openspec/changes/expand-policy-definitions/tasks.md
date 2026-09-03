## 1. Definition detail resolution (bash)

- [ ] 1.1 Build the distinct set of `definitionName` values from `RELEVANT_DENY_MODIFY_JSON`
      (dedup before issuing any `az` calls)
- [ ] 1.2 For each distinct name, call `az policy definition show --name "<name>"` (read-only,
      wrapped with the existing `run_az_json` best-effort helper); on failure emit
      `{ name, error }` instead of aborting
- [ ] 1.3 Normalize each resolved definition into `{ name, id, displayName, description,
      policyType, mode, version, metadata, parameters, policyRule, roleDefinitionIds }`,
      applying `//`-fallback for any field name casing variance
- [ ] 1.4 Assemble `POLICY_DEFINITIONS_DETAIL_JSON` from the resolved/error entries

## 2. Assignment detail attachment (bash)

- [ ] 2.1 Build a `assignmentName -> assignment record` lookup from `ASSIGNMENTS_VISIBLE_JSON`
      (e.g. via `jq` `INDEX(.name)`)
- [ ] 2.2 For each `RELEVANT_DENY_MODIFY_JSON` entry, look up its `assignmentName` in the map and
      attach `assignmentDetail: { name, displayName, scope, policyDefinitionId, parameters,
      enforcementMode, notScopes, nonComplianceMessages, identity }`, or `null` if not found
- [ ] 2.3 Produce the updated `RELEVANT_DENY_MODIFY_JSON` with `assignmentDetail` inlined

## 3. Simplified constraint summary (bash)

- [ ] 3.1 Implement a generic `jq` recursive walk over `policyRule.if` (and nested
      `allOf`/`anyOf`/`not`) that finds every object containing a `field` key and captures
      `{ field, operator, value }`
- [ ] 3.2 Classify each captured condition into `resourceTypesAffected` / `namingRules` /
      `resourceGroupRules` / `locationRules` / `networkRules` / `tagRules` per the field-matching
      rules in design.md; leave unmatched conditions out of the summary
- [ ] 3.3 Assemble one summary record per resolved definition:
      `{ definitionName, displayName, effect, resourceTypesAffected, namingRules,
      resourceGroupRules, locationRules, networkRules, tagRules }`
- [ ] 3.4 Add the summary array to the output JSON (alongside `policy.definitionsDetail`)

## 4. Mirror in PowerShell

- [ ] 4.1 Port task group 1 (definition detail resolution) to `discover-subscription.ps1`,
      reusing the `Invoke-AzJson` best-effort pattern and a `HashSet[string]`-based dedup for
      distinct definition names (consistent with the existing policy-tuple dedup fix)
- [ ] 4.2 Port task group 2 (assignment detail attachment) using a hashtable keyed by
      `assignmentName`
- [ ] 4.3 Port task group 3 (simplified constraint summary) as a recursive PowerShell function
      walking the deserialized `policyRule` object graph; apply the same array-unwrapping
      precautions already established in this script (direct `@()` wrapping, no if/else-as-
      expression capture of array-typed results, `[string[]]` casts where needed) for every new
      array-valued field (`resourceTypesAffected`, `namingRules`, etc.)

## 5. Verification

- [ ] 5.1 Run both scripts against the live test subscription; confirm `policy.definitionsDetail`
      and `policy.relevantDenyOrModify[].assignmentDetail` are populated and match between bash
      and PowerShell (modulo array ordering, consistent with prior verification runs)
- [ ] 5.2 Confirm at least one single-value array field in the new output (e.g. a definition with
      exactly one `roleDefinitionIds` entry, or a simplified-summary bucket with exactly one
      condition) serializes as a JSON array in the PowerShell output, not a bare scalar
- [ ] 5.3 Confirm a deliberately-inaccessible or nonexistent definition name produces an
      `{ name, error }` entry without aborting the rest of discovery, in both scripts
- [ ] 5.4 Update `scripts/README.md` to document the new `policy.definitionsDetail` array, the
      `assignmentDetail` field on shortlist entries, and the simplified constraint summary
- [ ] 5.5 Mark all tasks in this file complete and run `openspec validate expand-policy-
      definitions --strict`
