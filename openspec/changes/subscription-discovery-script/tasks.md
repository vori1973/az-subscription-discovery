## 1. Script scaffolding

- [x] 1.1 Create script entry point (bash, using `az cli`) that accepts `--subscription` (repeatable) and `--management-group` (optional) arguments, defaulting subscription to `az account show --query id`
- [x] 1.2 Add `--output` argument (path to write JSON; default stdout) and basic `--help` usage text
- [x] 1.3 Set up error handling so a failure in one section logs a warning and continues rather than aborting the whole run

## 2. Resource group and networking discovery

- [x] 2.1 Implement resource group listing (`az group list`) capturing name, location, tags per target subscription
- [x] 2.2 Implement VNet/subnet discovery (`az network vnet list` + subnet details) capturing name, resource ID, subscription ID, resource group, address space, and subnets (name, prefix, delegation)
- [x] 2.3 Implement VNet peering discovery, capturing remote VNet ID and remote subscription ID for each peering
- [x] 2.4 Ensure every VNet/subnet/peering record includes its own subscription ID (do not assume it matches the scanned subscription)

## 3. Policy discovery

- [x] 3.1 Implement `policy.assignmentsVisible` via `az policy assignment list --disable-scope-strict-match`
- [x] 3.2 Implement `policy.effectiveFromComplianceState` via `az policy state list`, deduping to distinct `(assignmentName, definitionName, scope, effect)` tuples
- [x] 3.3 Implement `policy.relevantDenyOrModify` filter over the compliance-state results, matching `Deny`/`Modify` effects or name patterns (`PublicNetwork`, `LocalAuth`, `SKU`, `Limit`, `Capacity`)
- [x] 3.4 If `--management-group` is supplied and accessible, attempt direct policy discovery at that scope in addition to the subscription-level `policy state list` fallback

## 4. Naming convention observation

- [x] 4.1 Implement best-effort naming pattern mining (common prefixes) over resource groups and VNets/subnets, grouped by resource type
- [x] 4.2 Label naming output as "observed" in the JSON structure, distinct from any policy-backed requirement

## 5. Output assembly

- [x] 5.1 Assemble the full JSON document per the schema in `design.md` (`meta`, `resourceGroups`, `networking`, `policy`, `namingObserved`, `quotas` placeholder)
- [x] 5.2 Populate `meta` with generation timestamp, tenant ID, target subscription IDs, and the identity the script ran as (`az account show`)
- [x] 5.3 Validate the assembled output is well-formed JSON before writing/printing it

## 6. Verification

- [x] 6.1 Run the script against a real subscription and confirm each section populates independently (including when management-group access is denied)
- [x] 6.2 Confirm no write/mutating Azure CLI calls are present anywhere in the script (read-only review)
- [x] 6.3 Document usage (inputs, required permissions, example invocation) in a README alongside the script
