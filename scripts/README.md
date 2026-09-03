# discover-subscription

Read-only Azure subscription discovery. Queries a subscription (and, where visible, its parent
management group) and emits a single structured JSON document describing what exists and what's
constrained — resource groups, VNets/subnets/peerings, effective policy, and observed naming
conventions — so that infrastructure parametrization decisions can be made from real subscription
state instead of assumptions. See `openspec/changes/subscription-discovery-script/design.md` for
the full output schema and rationale.

Two functionally equivalent implementations are provided, producing identical JSON output:

- **`discover-subscription.sh`** (bash + `jq`) — for Linux/macOS/WSL/Git Bash.
- **`discover-subscription.ps1`** (PowerShell 7+) — for native PowerShell hosts (Windows,
  cross-platform).

Both perform **no write operations against Azure**; they only issue `list`/`show`-style Azure CLI
calls.

## Requirements

| | Bash | PowerShell |
| --- | --- | --- |
| Runtime | bash | PowerShell 7+ (`pwsh`) — Windows PowerShell 5.1 is not supported |
| Extra tooling | [`jq`](https://jqlang.github.io/jq/) | none (uses `ConvertTo-Json`/`ConvertFrom-Json`) |

Both require [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az`), logged in (`az login`),
and `Reader` role on each target subscription (sufficient for all sections; no write permissions
are required or used anywhere in either script).

## Usage

```bash
./scripts/discover-subscription.sh [--subscription <id>]... [--management-group <id>] [--output <path>]
```

```powershell
./scripts/discover-subscription.ps1 [-Subscription <id[],...>] [-ManagementGroup <id>] [-Output <path>]
```

| Bash option | PowerShell parameter | Description |
| --- | --- | --- |
| `--subscription <id>` (repeatable) | `-Subscription <string[]>` | Target subscription ID(s) or name(s). Defaults to the subscription currently active in the caller's Azure CLI context (`az account show`) when omitted. In PowerShell, pass multiple values as a comma-separated array (`-Subscription sub-a,sub-b`); repeating the flag does not accumulate values the way the bash `--subscription` flag does. |
| `--management-group <id>` | `-ManagementGroup <string>` | Optional management group ID. If supplied and accessible, attempts direct policy discovery at that scope in addition to the subscription-level `az policy state list` fallback. |
| `--output <path>` | `-Output <string>` | File path to write the JSON output. Defaults to stdout. |
| `-h`, `--help` | `Get-Help ./scripts/discover-subscription.ps1 -Full` | Show usage text. |

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

```powershell
# Discover the currently active subscription, print JSON to stdout
./scripts/discover-subscription.ps1

# Discover a specific subscription, write to a file
./scripts/discover-subscription.ps1 `
  -Subscription 00000000-0000-0000-0000-000000000000 `
  -Output discovery.json

# Discover multiple subscriptions and attempt management-group-level policy discovery
./scripts/discover-subscription.ps1 -Subscription sub-a,sub-b -ManagementGroup mg-contoso
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

- Discovery runs independently per subscription; a failure against one does not block discovery
  of the others.
- No `az account set` or other calls that mutate the caller's CLI context are made; every `az`
  call is scoped explicitly with `--subscription`/`--scope`.
- Both scripts have been verified to produce equivalent JSON output against the same live
  subscription.
