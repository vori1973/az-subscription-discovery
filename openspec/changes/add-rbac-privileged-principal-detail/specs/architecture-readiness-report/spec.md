## ADDED Requirements

### Requirement: Privileged RBAC assignment detail
The RBAC Ownership section SHALL include a distinct "Privileged Role Assignments" sub-section
listing individual assignments — principal ID, principal type, role name, and scope — for a
bounded set of high-privilege roles: the built-in roles `Owner`, `Contributor`, and `User Access
Administrator`, plus any role definition name containing `Owner` or `Admin` (case-insensitive).
This sub-section SHALL be sourced only from data already present in the input JSON's
`rbac.assignments` (no additional lookups), and SHALL appear even when no assignment matches the
filter, explicitly stating that none were found.

#### Scenario: Privileged assignments present
- **WHEN** the input's `rbac.assignments` contains one or more entries whose
  `roleDefinitionName` is `Owner`, `Contributor`, `User Access Administrator`, or contains
  `Owner`/`Admin` (case-insensitive)
- **THEN** the RBAC Ownership section includes a "Privileged Role Assignments" sub-section
  listing each matching assignment's principal ID, principal type, role name, and scope

#### Scenario: No privileged assignments found
- **WHEN** none of the input's `rbac.assignments` entries match the privileged-role filter
- **THEN** the "Privileged Role Assignments" sub-section is still present and explicitly states
  that no privileged assignments were found

#### Scenario: RBAC data unavailable
- **WHEN** the input JSON has no `rbac` section (or discovery failed to list assignments)
- **THEN** the "Privileged Role Assignments" sub-section is omitted along with the rest of the
  RBAC Ownership section, consistent with existing handling of missing sections
