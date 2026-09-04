## Purpose

Reports RBAC assignments, resource provider registration state, existing private endpoints and
private DNS zones, and real subscription/network quota usage, so a reviewer can judge whether a
subscription is ready to host a new platform workload without running several manual `az` calls.

## ADDED Requirements

### Requirement: RBAC discovery
The system SHALL discover role assignments (`az role assignment list --all`) and custom role
definitions (`az role definition list`, filtered to custom roles) in each target subscription,
reporting each assignment's principal ID, principal type, role definition name, and scope, and
each custom role's name, ID, and assignable scopes. The system SHALL also report a best-effort
per-principal ownership summary counting assignments by role name. This section is independent
and best-effort: an access denial or failure while listing RBAC data SHALL NOT prevent any other
section from being gathered and reported.

#### Scenario: Role assignments and custom roles present
- **WHEN** the target subscription has one or more role assignments and custom role definitions
- **THEN** the output's `rbac` section reports `assignments` (principal ID, principal type, role
  name, scope) and `customRoles` (name, ID, assignable scopes) for all discoverable entries

#### Scenario: RBAC listing access denied
- **WHEN** the caller lacks permission to list role assignments or role definitions
- **THEN** the `rbac` section reports the failure without aborting discovery of any other section

### Requirement: Resource provider registration discovery
The system SHALL discover the registration state of a fixed priority list of resource providers
relevant to common platform workloads — at minimum `Microsoft.CognitiveServices`,
`Microsoft.ApiManagement`, `Microsoft.Search`, `Microsoft.ContainerService`,
`Microsoft.KeyVault`, `Microsoft.Web`, `Microsoft.Network`, and `Microsoft.OperationalInsights` —
using `az provider list`, reporting each provider's namespace and registration state
(`Registered`, `NotRegistered`, `Registering`, or unavailable).

#### Scenario: Mixed registration states
- **WHEN** some priority providers are registered and others are not
- **THEN** the output's `providers` section reports the registration state of every priority
  provider individually, without omitting unregistered ones

### Requirement: Private Endpoint discovery
The system SHALL discover all private endpoints in each target subscription
(`az network private-endpoint list`), reporting each endpoint's name, resource group, subnet
reference, and its private-link service connection's target resource ID and connection status.

#### Scenario: Private endpoints present
- **WHEN** one or more private endpoints exist in the target subscription
- **THEN** the output's `privateEndpoints` section lists each with its name, resource group,
  subnet, target resource ID, and connection status

#### Scenario: No private endpoints
- **WHEN** no private endpoints exist in the target subscription
- **THEN** the output's `privateEndpoints` section reports an empty list rather than omitting the
  section

### Requirement: Private DNS discovery
The system SHALL discover private DNS zones (`az network private-dns zone list`) and their
virtual network links (`az network private-dns link vnet list`) in each target subscription,
reporting each zone's name and the names of the VNets linked to it.

#### Scenario: Zones with linked VNets
- **WHEN** one or more private DNS zones exist with VNet links
- **THEN** the output's `privateDns` section reports each zone's name together with the list of
  VNet names linked to it

#### Scenario: Zone with no links
- **WHEN** a private DNS zone exists with no VNet links
- **THEN** that zone still appears in the `privateDns` section with an empty link list

### Requirement: Subscription and network quota usage
The system SHALL report real compute quota usage (`az vm list-usage`) and network quota usage
(`az network list-usages`) for each Azure region already observed among the subscription's
discovered VNets, falling back to the subscription's default location when no VNets were
discovered. Each reported quota entry SHALL include its region, name, current value, and limit.
This replaces the previously placeholder `quotas` section with real data.

#### Scenario: Regions derived from discovered VNets
- **WHEN** the subscription has VNets discovered in one or more regions
- **THEN** the `quotas` section reports compute and network usage for each of those regions

#### Scenario: No VNets discovered
- **WHEN** the subscription has no discovered VNets
- **THEN** the `quotas` section reports compute and network usage for the subscription's default
  location instead of being empty

#### Scenario: Quota listing access denied
- **WHEN** the caller lacks permission to list usage for a given region
- **THEN** that region's quota entry reports the failure without aborting discovery of any other
  section or region
