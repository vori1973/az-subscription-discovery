## MODIFIED Requirements

### Requirement: Structured JSON output
The system SHALL emit a single JSON document containing `meta`, `resourceGroups`, `networking`,
`policy`, `namingObserved`, `quotas`, and `architectureConstraints` top-level sections, with
`quotas` reserved as a placeholder for a future iteration and `architectureConstraints`
containing best-effort, synthesized cross-section facts (see the
`architecture-constraint-synthesis` capability).

#### Scenario: Output is machine-parsable
- **WHEN** the script completes successfully
- **THEN** it produces one valid JSON document containing all defined top-level sections, usable
  as input to downstream review or tooling
