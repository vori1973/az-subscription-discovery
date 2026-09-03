# discover-subscription.sh

Read-only Azure subscription discovery. Queries a subscription (and, where visible, its parent
management group) and emits a single structured JSON document describing what exists and what's
constrained — resource groups, VNets/subnets/peerings, effective policy, and observed naming
conventions — so that infrastructure parametrization decisions can be made from real subscription
state instead of assumptions. See `openspec/changes/subscription-discovery-script/design.md` for
the full output schema and rationale.

The script performs **no write operations against Azure**; it only issues `list`/`show`-style
Azure CLI calls.

## Requirements

- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az`), logged in (`az login`)
- [`jq`](https://jqlang.github.io/jq/)
- `Reader` role on each target subscription (sufficient for all sections; no write permissions
  are required or used anywhere in the script)

## Usage

```bash
./scripts/discover-subscription.sh [--subscription <id>]... [--management-group <id>] [--output <path>]
```

| Option | Description |
| --- | --- |
| `--subscription <id>` | Target subscription ID or name (repeatable). Defaults to the subscription currently active in the caller's Azure CLI context (`az account show`) when omitted. |
| `--management-group <id>` | Optional management group ID. If supplied and accessible, attempts direct policy discovery at that scope in addition to the subscription-level `az policy state list` fallback. |
| `--output <path>` | File path to write the JSON output. Defaults to stdout. |
| `-h`, `--help` | Show usage text and exit. |

### Examples

```bash
# Discover the currently active subscription, print JSON to stdout
./scripts/discover-subscription.sh

# Discover a specific subscription, write to a file
./scripts/discover-subscription.sh \
  --subscription 00000000-0000-0000-0000-000000000000 \
  --output discovery.json

# Discover multiple subscriptions and attempt management-group-level policy discovery
./scripts/discover-subscription.sh \
  --subscription sub-a --subscription sub-b \
  --management-group mg-contoso
```

## Output

A single JSON document with independent, best-effort top-level sections: `meta`,
`resourceGroups`, `networking`, `policy`, `namingObserved`, and a reserved `quotas` placeholder.
A failure or access denial while gathering one section (e.g. no management-group access) is
logged as a warning to stderr and does not prevent the other sections from populating.

Notable details:

- Every VNet/subnet/peering record includes its own `subscriptionId`, since a peered or
  cross-subscription-referenced VNet may live in a different subscription than the one being
  scanned.
- `policy.effectiveFromComplianceState` (derived from `az policy state list`) is the primary
  source of truth for effective policy, including management-group-inherited rules that may be
  invisible to `policy.assignmentsVisible` (`az policy assignment list`) when the caller lacks
  Reader at the assignment's scope.
- `policy.relevantDenyOrModify` is a shortlist of policies most likely to constrain resource
  shape (matching `Deny`/`Modify` effects or name patterns like `PublicNetwork`, `LocalAuth`,
  `SKU`, `Limit`, `Capacity`).
- `namingObserved` is best-effort pattern mining over existing resource names, explicitly labeled
  "observed" — not an enforced rule unless corroborated by an entry in `policy`.
- `quotas` is a reserved placeholder for a future iteration (e.g. Cognitive Services / VM usage
  quotas) — present but empty in this version.

## Notes

- Discovery runs independently per `--subscription`; a failure against one subscription does not
  block discovery of the others.
- No `az account set` or other calls that mutate the caller's CLI context are made; every `az`
  call is scoped explicitly with `--subscription`/`--scope`.
