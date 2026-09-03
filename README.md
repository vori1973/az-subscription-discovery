# az-subscription-discovery

Read-only Azure subscription discovery scripts. They query a subscription (and, where visible,
its parent management group) and emit a single structured JSON document describing what exists
and what's constrained — resource groups, VNets/subnets/peerings, effective policy (including
resolved Deny/Modify policy definitions and assignments), observed naming conventions, and
synthesized cross-section architecture facts (hub VNet, required tags, naming) — so
infrastructure parametrization decisions can be made from real subscription state instead of
assumptions.

Two functionally equivalent implementations are provided, producing identical JSON output:

- `scripts/discover-subscription.sh` (bash + `jq`) — for Linux/macOS/WSL/Git Bash.
- `scripts/discover-subscription.ps1` (PowerShell 7+) — for native PowerShell hosts.

Both perform **no write operations against Azure** — only `list`/`show`-style Azure CLI calls.

See [`scripts/README.md`](scripts/README.md) for requirements, usage, and full output schema
documentation.

## Development workflow

This project uses [OpenSpec](https://github.com/Fission-AI/OpenSpec) for spec-driven
development — specs are the source of truth for behavior, and code follows them. See
[`AGENTS.md`](AGENTS.md) for the full workflow (`/opsx-propose`, `/opsx-apply`, `/opsx-archive`)
and repository conventions. Active and archived changes live under `openspec/changes/`, and
baseline capability specs live under `openspec/specs/`.
