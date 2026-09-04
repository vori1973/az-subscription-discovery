## 1. Implementation

- [ ] 1.1 Add a `PRIVILEGED_ROLE_PATTERN`/helper predicate in
      `scripts/generate-readiness-report.py` that matches a `roleDefinitionName` of `Owner`,
      `Contributor`, or `User Access Administrator` (built-ins), or any role name containing
      `owner`/`admin` case-insensitively (covers custom roles).
- [ ] 1.2 In `render_rbac()`, filter `rbac.assignments` through that predicate and render a new
      "Privileged Role Assignments" sub-section (`### Privileged Role Assignments`) as a table
      with columns Principal ID, Principal Type, Role, Scope.
- [ ] 1.3 When no assignment matches the filter, render the sub-section with an explicit
      "No privileged role assignments found." line instead of an empty table.
- [ ] 1.4 Leave the existing role→count summary table untouched; the new sub-section is
      additive and appears after it, still under the `## RBAC Ownership` heading.

## 2. Validation

- [ ] 2.1 Regenerate `out/report-DiscoveryPlusv2.md` from `out/DiscoveryPlusv2.json` and confirm
      the new sub-section lists individual `Owner`/`Contributor`/admin-role assignments with
      principal ID, type, and scope, matching what's in `rbac.assignments`.
- [ ] 2.2 Manually construct or use an existing sample JSON with an empty/missing `rbac`
      assignments list and confirm the sub-section still renders with the "none found" message,
      and that a missing `rbac` section still omits the whole RBAC Ownership section as before.
- [ ] 2.3 Run `openspec validate add-rbac-privileged-principal-detail --strict` and fix any
      reported issues before archiving.
