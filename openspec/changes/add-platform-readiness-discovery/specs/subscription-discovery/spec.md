## MODIFIED Requirements

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
