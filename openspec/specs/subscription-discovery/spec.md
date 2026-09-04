## Purpose

Provides read-only discovery of an Azure subscription's existing resources, networking topology,
effective policy constraints, and observed naming conventions, emitting a single structured JSON
artifact that downstream tooling or reviewers can use to reason about how to parametrize
infrastructure for that subscription.

## Requirements

### Requirement: Read-only operation
The system SHALL only perform read/list/get operations against Azure APIs. It SHALL NOT create,
modify, or delete any Azure resource, policy, or configuration.

#### Scenario: No write calls issued
- **WHEN** the discovery script is run against any subscription
- **THEN** only read-only Azure CLI/API calls (list, show, get) are issued and no resource state
  in Azure is changed

### Requirement: Subscription and management group input
The system SHALL accept one or more target subscription IDs as input, defaulting to the
currently active `az account show` subscription when none are supplied. The system SHALL accept
an optional management group ID to attempt policy discovery at that scope.

#### Scenario: No subscription supplied
- **WHEN** the script is invoked with no subscription ID argument
- **THEN** it targets the subscription currently active in the caller's Azure CLI context

#### Scenario: Explicit subscription list supplied
- **WHEN** the script is invoked with one or more subscription IDs
- **THEN** it runs discovery independently against each supplied subscription

### Requirement: Independent, best-effort sections
The system SHALL organize output into independent sections (resource groups, networking, policy,
naming, quotas). A failure or access denial while gathering one section SHALL NOT prevent the
other sections from being gathered and reported.

#### Scenario: Management group access denied
- **WHEN** the caller lacks Reader access at the management group scope
- **THEN** the policy section still reports results derived from `az policy state list`, and all
  other sections (resource groups, networking, naming) are populated normally

### Requirement: Resource group and networking discovery
The system SHALL discover all resource groups in each target subscription (name, location, tags)
and all virtual networks (name, resource ID, subscription ID, resource group, address space,
subnets, and peerings). Each VNet and subnet record SHALL include the subscription ID it belongs
to, without assuming it matches the subscription being targeted for workload deployment.

#### Scenario: VNet in a different subscription than the workload
- **WHEN** a peered or referenced VNet lives in a subscription other than the one being scanned
- **THEN** its record includes its own subscription ID so cross-subscription topology is visible
  in the output

### Requirement: Effective policy discovery
The system SHALL determine effective policy constraints using `az policy state list` (compliance
evaluation results) as the primary source, because it surfaces management-group-inherited policy
even when the caller cannot see the assignment object directly. The system SHALL also report the
raw output of `az policy assignment list` for completeness, while documenting that it may be
incomplete. The system SHALL provide a filtered shortlist of policies whose name or effect
suggests they constrain resource shape (e.g. `Deny`, `Modify` effects, or names matching patterns
like `PublicNetwork`, `LocalAuth`, `SKU`, `Limit`, `Capacity`).

For every distinct policy definition name appearing in the Deny/Modify shortlist, the system
SHALL additionally resolve and report the full policy definition (via `az policy definition
show`), including at minimum: `name`, `id`, `displayName`, `description`, `policyType`, `mode`,
`version`, `metadata`, `parameters`, `policyRule`, and `roleDefinitionIds`. This resolution is
read-only, performed independently per definition, and best-effort: if a given definition cannot
be resolved (e.g. an inaccessible custom definition scope), the system SHALL report that
definition's name together with an error indicator rather than aborting discovery or omitting
the rest of the output. Definitions referenced only by policies outside the Deny/Modify
shortlist (e.g. `Audit`/`AuditIfNotExists` effects) are not resolved.

For every Deny/Modify shortlist entry, the system SHALL additionally attach the matching policy
*assignment* detail (sourced from the already-collected `az policy assignment list` results),
including at minimum: `name`, `displayName`, `scope`, `policyDefinitionId`, `parameters`,
`enforcementMode`, `notScopes`, `nonComplianceMessages`, and `identity`. When the assignment is
not visible to the caller (e.g. it is inherited from a management group scope the caller cannot
enumerate directly), this assignment detail SHALL be omitted for that entry without affecting
the rest of the output.

For every resolved policy definition, the system SHALL additionally report a simplified,
best-effort constraint summary derived from its `policyRule`: `definitionName`, `displayName`,
`effect`, `resourceTypesAffected`, `namingRules`, `resourceGroupRules`, `locationRules`,
`networkRules`, and `tagRules`. This summary is produced by a generic, non-exhaustive heuristic
scan of the `policyRule` condition tree and is explicitly informational rather than a guaranteed
complete or semantically precise evaluation of the policy's logic.

#### Scenario: Management-group-inherited policy invisible to assignment list
- **WHEN** a policy is assigned at a management group scope the caller cannot enumerate directly
- **THEN** it still appears in the effective-policy section because it is derived from
  `az policy state list` compliance results rather than the assignment list

#### Scenario: Deny/Modify shortlist
- **WHEN** effective policies include definitions with `Deny` or `Modify` effects
- **THEN** those definitions appear in a distinct shortlist section separate from the full
  effective-policy list

#### Scenario: Deny/Modify definition detail resolved
- **WHEN** the Deny/Modify shortlist contains a definition name
- **THEN** the output includes a corresponding definition detail record with its `displayName`,
  `description`, `policyType`, `mode`, `version`, `metadata`, `parameters`, `policyRule`, and
  `roleDefinitionIds`

#### Scenario: Definition detail unresolvable
- **WHEN** `az policy definition show` fails for one of the shortlisted definition names (e.g.
  the caller lacks access to a custom definition's scope)
- **THEN** the output still includes an entry for that definition name with an error indicator,
  and discovery of all other sections continues unaffected

#### Scenario: Duplicate definition names across shortlist entries
- **WHEN** the same policy definition name appears multiple times in the Deny/Modify shortlist
  (e.g. assigned at multiple scopes)
- **THEN** its definition detail is resolved and reported only once

#### Scenario: Assignment detail attached when visible
- **WHEN** a Deny/Modify shortlist entry's assignment is visible via `az policy assignment list`
- **THEN** the entry includes assignment detail with its `name`, `displayName`, `scope`,
  `policyDefinitionId`, `parameters`, `enforcementMode`, `notScopes`,
  `nonComplianceMessages`, and `identity`

#### Scenario: Assignment detail omitted when not visible
- **WHEN** a Deny/Modify shortlist entry's assignment is inherited from a management group scope
  the caller cannot enumerate directly
- **THEN** the entry's assignment detail is omitted while its definition detail and other fields
  are still reported

#### Scenario: Simplified constraint summary bucketed by field category
- **WHEN** a resolved definition's `policyRule` contains conditions referencing `name`,
  `resourceGroup`, `location`, `tags`, or `Microsoft.Network/*`-related fields
- **THEN** the simplified summary buckets those conditions into `namingRules`,
  `resourceGroupRules`, `locationRules`, `tagRules`, and `networkRules` respectively

#### Scenario: Unrecognized condition fields omitted from the simplified summary
- **WHEN** a `policyRule` condition references a field that does not match any of the defined
  categories
- **THEN** that condition is left out of the simplified summary but remains present in the raw
  `policyRule` reported alongside it

### Requirement: Observed naming convention reporting
The system SHALL report naming patterns observed in existing resource names (e.g. common
prefixes), grouped by resource type, and SHALL label this output as observed/best-effort rather
than authoritative. The system SHALL NOT treat an observed naming pattern as an enforced rule
unless it is corroborated by a policy definition found in the policy section.

#### Scenario: Naming pattern with no corroborating policy
- **WHEN** resource names share a common prefix but no policy definition enforces it
- **THEN** the pattern appears only in the naming section labeled as observed, not as a
  requirement

### Requirement: Structured JSON output
The system SHALL emit a single JSON document containing `meta`, `resourceGroups`, `networking`,
`policy`, `rbac`, `providers`, `privateEndpoints`, `privateDns`, `namingObserved`, `quotas`, and
`architectureConstraints` top-level sections. `rbac`, `providers`, `privateEndpoints`, and
`privateDns` contain the RBAC, provider registration, private endpoint, and private DNS discovery
results (see the `platform-readiness-discovery` capability). `quotas` contains real
compute/network usage data (see `platform-readiness-discovery`) rather than being a placeholder.
`architectureConstraints` contains best-effort, synthesized cross-section facts (see the
`architecture-constraint-synthesis` capability).

#### Scenario: Output is machine-parsable
- **WHEN** the script completes successfully
- **THEN** it produces one valid JSON document containing all defined top-level sections, usable
  as input to downstream review or tooling
