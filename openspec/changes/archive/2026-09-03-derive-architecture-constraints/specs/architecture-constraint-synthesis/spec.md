## Purpose

Synthesizes a small set of cross-section, best-effort architecture facts (hub network
identification, observed naming, and policy-enforced tags) from data already collected by the
other discovery capabilities, so reviewers don't have to manually cross-reference sections.

## ADDED Requirements

### Requirement: Hub VNet identification
The system SHALL attempt to identify the subscription's "hub" VNet — the VNet with the largest
number of peerings to other VNets in the discovered topology — and report its name as
`hubPeering` and its resource group as `networkResourceGroup`. This identification is
heuristic: it SHALL be labeled as best-effort/observed, not authoritative, and the system SHALL
NOT fail or omit other `architectureConstraints` fields if no VNet can be confidently identified
as a hub (e.g. no peerings exist, or multiple VNets tie for the highest peering count).

#### Scenario: Single VNet with the most peerings
- **WHEN** exactly one VNet has strictly more peering connections than any other discovered VNet
- **THEN** that VNet's name is reported as `hubPeering` and its resource group as
  `networkResourceGroup`

#### Scenario: No clear hub
- **WHEN** no VNet has peerings, or multiple VNets tie for the highest peering count
- **THEN** `hubPeering` and `networkResourceGroup` are reported as `null` and the rest of
  `architectureConstraints` is still populated

### Requirement: Hub VNet address space surfacing
The system SHALL report the identified hub VNet's address space as `vnetAddressSpace` when a
hub VNet is identified, by cross-referencing the VNet name against the already-discovered
`networking.vnets` section.

#### Scenario: Hub identified
- **WHEN** a hub VNet is identified per the hub-identification requirement
- **THEN** `vnetAddressSpace` reflects that VNet's `addressSpace` from `networking.vnets`

#### Scenario: No hub identified
- **WHEN** no hub VNet is identified
- **THEN** `vnetAddressSpace` is reported as `null`

### Requirement: Observed resource group naming surfacing
The system SHALL report the observed resource group naming pattern as `resourceGroupNaming`,
sourced from the existing `namingObserved.resourceGroups` summary, labeled the same
observed/best-effort way as its source.

#### Scenario: Common prefix observed
- **WHEN** `namingObserved.resourceGroups` reports one or more common prefixes
- **THEN** `resourceGroupNaming` surfaces that same observed pattern

### Requirement: Policy-enforced tag key extraction
The system SHALL report the distinct set of tag keys referenced by any Deny/Modify/Append policy
condition as `requiredTags`, derived from the `tagRules` bucket already produced per policy
definition (see the `expand-policy-definitions` change). This is a best-effort extraction of tag
*keys* referenced in policy conditions, not a guarantee that every referenced key is strictly
required on every resource type (that depends on each policy's scope and effect, which is not
re-evaluated here).

#### Scenario: Tag keys found across multiple policies
- **WHEN** more than one resolved policy definition's `tagRules` bucket references tag keys
- **THEN** `requiredTags` contains the deduplicated union of those keys

#### Scenario: No tag-related policy conditions found
- **WHEN** no resolved policy definition's `tagRules` bucket references any tag key
- **THEN** `requiredTags` is reported as an empty array
