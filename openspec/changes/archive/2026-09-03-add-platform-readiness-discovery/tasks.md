## 1. Bash: RBAC discovery

- [x] 1.1 Add "4. Platform readiness discovery" section header to `discover-subscription.sh`
      (after "3. Policy", before the renumbered "5. Observed naming conventions"), and renumber
      all subsequent sections (naming → 5, architecture constraints → 6, assemble output → 7).
- [x] 1.2 Implement RBAC discovery: `az role assignment list --all` and `az role definition list`
      (custom roles only) per subscription via `run_az_json`, building `RBAC_JSON` with
      `assignments` (principalId, principalType, roleDefinitionName, scope, subscriptionId),
      `customRoles` (name, id, assignableScopes), and a per-role-name `ownershipSummary` count.

## 2. Bash: Providers, private endpoints, private DNS, quotas

- [x] 2.1 Implement provider registration discovery: `az provider list` per subscription,
      filtered to the fixed priority list (Microsoft.CognitiveServices, Microsoft.ApiManagement,
      Microsoft.Search, Microsoft.ContainerService, Microsoft.KeyVault, Microsoft.Web,
      Microsoft.Network, Microsoft.OperationalInsights), building `PROVIDERS_JSON` with
      namespace + registrationState for every priority provider (including unregistered ones).
- [x] 2.2 Implement private endpoint discovery: `az network private-endpoint list` per
      subscription, building `PRIVATE_ENDPOINTS_JSON` with name, resource group, subnet
      reference, and private-link connection target/status; empty list when none exist.
- [x] 2.3 Implement private DNS discovery: `az network private-dns zone list` plus
      `az network private-dns link vnet list` per zone, building `PRIVATE_DNS_JSON` with each
      zone's name and its linked VNet names (empty link list when a zone has no links).
- [x] 2.4 Implement quota/usage discovery: derive the region list from already-discovered VNets
      (dedup), falling back to the subscription's default location from `meta` when no VNets
      exist; call `az vm list-usage --location` and `az network list-usages --location` per
      region via `run_az_json` (best-effort per region), building `QUOTAS_JSON` with region,
      name, currentValue, and limit for each entry.
- [x] 2.5 Assemble `PLATFORM_READINESS_JSON` from the above and wire `rbac`, `providers`,
      `privateEndpoints`, `privateDns`, and `quotas` into `FINAL_JSON` (replacing the old
      placeholder `quotas` value).

## 3. Bash verification

- [x] 3.1 Run `bash -n scripts/discover-subscription.sh` to confirm syntax is valid.
- [x] 3.2 Run the script live against the test subscription; confirm `rbac`, `providers`,
      `privateEndpoints`, `privateDns`, and `quotas` are populated with plausible data and no
      section failure aborts the rest of discovery.
- [x] 3.3 Verify best-effort behavior: temporarily point quota/RBAC calls at an inaccessible
      scope (or simulate a failure) and confirm the affected section reports an error/empty
      result while every other section still populates normally.

## 4. PowerShell port

- [x] 4.1 Port section 4 (RBAC) to `discover-subscription.ps1`, renumbering subsequent sections
      to match the bash script exactly.
- [x] 4.2 Port provider registration, private endpoint, and private DNS discovery to
      `discover-subscription.ps1`, matching the bash JSON shape field-for-field.
- [x] 4.3 Port quota/usage discovery to `discover-subscription.ps1`, including the
      derived-region-with-fallback logic, and wire all five new sections into `$FinalObject`.

## 5. PowerShell verification and documentation

- [x] 5.1 Run the PowerShell parser check (e.g. `pwsh -NoProfile -Command "... AST parse ..."`
      or equivalent) to confirm syntax is valid.
- [x] 5.2 Run the PowerShell script live against the test subscription and diff its output
      against the bash script's output for structural equivalence (same sections, same shape).
- [x] 5.3 Verify single-element arrays (e.g. a subscription with exactly one custom role, one
      private endpoint, or one linked VNet) serialize as JSON arrays, not collapsed scalars.
- [x] 5.4 Update `scripts/README.md` documenting the new `rbac`, `providers`,
      `privateEndpoints`, `privateDns`, and populated `quotas` sections, including the fixed
      provider priority list.
- [x] 5.5 Run `openspec validate add-platform-readiness-discovery --strict` and confirm it
      passes.
