## Why

The discovery scripts (`discover-subscription.sh`/`.ps1`) already produce a rich JSON document
covering resource groups, networking, policy, RBAC, provider registration, private
endpoints/DNS, quotas, and synthesized architecture constraints. That JSON is complete but not
directly consumable by a human architect — reviewing it today means manually reading a
multi-thousand-line file (e.g. `out/discovery-test-1.2.json` runs to 1700+ quota entries alone)
and mentally cross-referencing sections to spot gaps like unregistered providers or
near-exhausted quotas. A generated, human-readable report over the same JSON would let an
architect assess subscription readiness in minutes instead of by hand-parsing raw output.

## What Changes

- Add a new report-generation script (`scripts/generate-readiness-report.py`, or `.sh`+`jq`
  equivalent — see design.md) that consumes an existing discovery JSON file and emits a Markdown
  report.
- The report SHALL organize findings by topic (subscription/meta, resource groups, networking
  topology, policy constraints, RBAC ownership, provider registration, private
  endpoints/DNS, quota headroom, and synthesized architecture constraints) rather than reproduce
  the raw JSON structure.
- The report SHALL surface risks/gaps explicitly — e.g. providers not `Registered`, quota
  entries above a configurable usage threshold, absence of an identified hub VNet — rather than
  only listing raw data.
- This is a pure post-processing step over already-collected discovery output: it issues no
  Azure API calls itself and does not modify the discovery scripts' JSON output shape.

### New Capabilities
- `architecture-readiness-report`: generates a human-readable Markdown report from a discovery
  JSON document, summarizing subscription readiness and flagging risks/gaps for an architect to
  review.

### Modified Capabilities
(none — this change only adds a new, independent reporting capability; it does not alter what
the discovery scripts collect or emit)

## Impact

- New file: `scripts/generate-readiness-report.py` (or equivalent), plus its own
  `scripts/README.md` documentation section.
- No changes to `discover-subscription.sh`/`.ps1` or their JSON output shape.
- No new Azure permissions or API calls — the tool only reads a JSON file already produced by
  the existing discovery scripts.
