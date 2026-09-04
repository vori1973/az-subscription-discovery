## Why

The Architecture Readiness Report's RBAC Ownership section only shows role→assignment-count
totals (e.g. "Owner: 44"), which cannot answer the natural follow-up question a reviewer asks
next: *which specific principals hold those high-privilege roles, and at what scope?* Today
answering that requires opening the raw discovery JSON and manually filtering `rbac.assignments`.
Surfacing this in the Markdown report directly saves that manual step for the access review that
already happens as part of readiness assessment.

## What Changes

- Add a new "Privileged Role Assignments" sub-section under RBAC Ownership in the generated
  Markdown report, listing individual assignments for a fixed set of high-privilege roles only
  (built-in `Owner`, `Contributor`, `User Access Administrator`, plus any custom role whose name
  contains `Owner` or `Admin`, case-insensitive) — not all 312 assignments.
- Each listed row shows: principal ID, principal type (User/Group/ServicePrincipal), role name,
  and scope, sourced directly from `rbac.assignments` (no additional Azure AD lookups, so no
  display names/emails are introduced — this stays within data already discovered).
- The sub-section appears even when no assignment matches the privileged-role filter, explicitly
  stating that none were found, consistent with how the existing Readiness Risks summary handles
  the empty case.
- The existing role→count summary table is unchanged; this is an additive sub-section, not a
  replacement.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `architecture-readiness-report`: the RBAC Ownership section requirement is extended to also
  report per-principal detail for a bounded set of high-privilege roles, in addition to the
  existing role→count summary.

## Impact

- `scripts/generate-readiness-report.py`: `render_rbac()` gains logic to filter
  `rbac.assignments` down to privileged roles and render the new sub-section.
- No changes to `discover-subscription.sh`/`.ps1` or the discovery JSON schema — this only
  consumes data already present in `rbac.assignments`.
- No new external dependencies or Azure API calls.
