## Purpose

Turns a discovery script's JSON output into a human-readable Markdown report that groups
findings by topic and explicitly flags readiness risks/gaps, so an architect can assess
subscription readiness without manually reading raw JSON.

## Requirements

### Requirement: Report generation from discovery JSON
The system SHALL provide a script that accepts a path to a JSON file produced by
`discover-subscription.sh`/`.ps1` and emits a Markdown report to stdout or a specified output
file. The system SHALL NOT issue any Azure API calls; it SHALL operate only on the supplied JSON
file's contents.

#### Scenario: Valid discovery JSON supplied
- **WHEN** the script is given a path to a well-formed discovery JSON file
- **THEN** it writes a Markdown report covering the subscription's discovered sections

#### Scenario: Missing or invalid input file
- **WHEN** the supplied path does not exist or does not contain valid JSON
- **THEN** the script reports a clear error and exits without producing a partial report

#### Scenario: Discovery JSON missing an expected section
- **WHEN** the input JSON lacks one of the sections the report normally covers (e.g. an older
  discovery output predating a given section)
- **THEN** the report omits or clearly labels that section as unavailable rather than failing to
  generate the rest of the report

### Requirement: Topic-organized report sections
The report SHALL organize content by topic rather than mirror the input JSON's structure,
covering at minimum: subscription metadata, resource groups, networking topology, policy
constraints, RBAC ownership, resource provider registration, private endpoints/DNS, quota
headroom, and synthesized architecture constraints, when the corresponding data is present in
the input.

#### Scenario: All sections present in input
- **WHEN** the input JSON contains all of the sections listed above
- **THEN** the report includes a corresponding heading and summary for each one

### Requirement: Readiness risk and gap flagging
The report SHALL include a distinct summary of readiness risks/gaps derived from the input data,
at minimum: resource providers whose registration state is not `Registered`, quota entries whose
usage ratio (`currentValue`/`limit`) meets or exceeds a threshold (default 80%, configurable via
a command-line option), and the absence of an identified hub VNet
(`architectureConstraints.hubPeering` is `null`). This summary SHALL appear even when it is
empty, explicitly stating that no risks were found, so its absence is never ambiguous with a
report that failed to run this check.

#### Scenario: Unregistered provider present
- **WHEN** the input's `providers` section contains an entry whose `registrationState` is not
  `Registered`
- **THEN** the risk summary lists that provider namespace and its actual state

#### Scenario: Quota near limit
- **WHEN** a quota entry's `currentValue` divided by its `limit` meets or exceeds the configured
  threshold
- **THEN** the risk summary lists that quota's region, name, current value, and limit

#### Scenario: No hub VNet identified
- **WHEN** `architectureConstraints.hubPeering` is `null`
- **THEN** the risk summary notes that no hub VNet was identified

#### Scenario: No risks found
- **WHEN** none of the configured risk conditions match any entry in the input
- **THEN** the risk summary section is still present and explicitly states that no risks were
  found
