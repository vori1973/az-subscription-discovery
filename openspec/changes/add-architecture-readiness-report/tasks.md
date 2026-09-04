## 1. Script scaffolding

- [x] 1.1 Create `scripts/generate-readiness-report.py` with CLI argument parsing: required
  input JSON path, optional `-o`/`--output` path (default stdout), optional
  `--quota-threshold` (default `0.8`).
- [x] 1.2 Implement input loading: read and `json.load` the input file, exiting with a clear
  error message (no partial output) on a missing file or a JSON parse error.

## 2. Topic-organized sections

- [x] 2.1 Render a subscription metadata section from `meta`.
- [x] 2.2 Render a resource groups section (count, names, locations) from `resourceGroups`.
- [x] 2.3 Render a networking topology section from `networking` (VNet count, address spaces,
  peering summary) plus `architectureConstraints.hubPeering`/`vnetAddressSpace`.
- [x] 2.4 Render a policy constraints section summarizing `policy.relevantDenyOrModify` and
  `architectureConstraints.requiredTags`.
- [x] 2.5 Render an RBAC ownership section from `rbac.ownershipSummary` (and note custom role
  count from `rbac.customRoles`).
- [x] 2.6 Render a provider registration section listing every entry in `providers` with its
  state.
- [x] 2.7 Render a private endpoints/DNS section summarizing `privateEndpoints` and
  `privateDns` counts and any DNS zones with no linked VNets.
- [x] 2.8 Render a quota headroom section from `quotas`, grouped by region.
- [x] 2.9 For each section, handle the corresponding top-level key being absent from the input
  JSON by labeling that section "not available in this discovery output" instead of raising an
  error.

## 3. Risk/gap summary

- [x] 3.1 Implement the unregistered-provider check: any `providers` entry whose
  `registrationState` is not `Registered`.
- [x] 3.2 Implement the quota-near-limit check: any `quotas` entry where
  `currentValue / limit >= threshold` (guarding against a zero/non-numeric `limit`).
- [x] 3.3 Implement the missing-hub-VNet check: `architectureConstraints.hubPeering is None`.
- [x] 3.4 Render the risk/gap summary section combining all three checks, explicitly stating
  "No risks found" when none match.

## 4. Verification

- [x] 4.1 Run the script against a real discovery JSON output (e.g. one generated earlier this
  session) and confirm every section renders with plausible content.
- [x] 4.2 Run the script against a discovery JSON with an intentionally missing section (e.g. an
  edited copy with `rbac` removed) and confirm that section is labeled unavailable rather than
  crashing.
- [x] 4.3 Verify the risk/gap summary correctly flags a manually-edited unregistered provider,
  a manually-edited near-limit quota entry, and a null `hubPeering`, and separately verify a
  clean input produces "No risks found".
- [x] 4.4 Confirm `-o`/`--output` writes to a file and omitting it prints to stdout.

## 5. Documentation and validation

- [x] 5.1 Document the new script in `scripts/README.md`: usage, CLI options, and what each
  report section covers.
- [x] 5.2 Run `openspec validate add-architecture-readiness-report --strict` and confirm it
  passes.
