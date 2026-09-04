## Context

The discovery scripts (`discover-subscription.sh`/`.ps1`) already write a single JSON document
with sections: `meta`, `resourceGroups`, `networking`, `policy`, `rbac`, `providers`,
`privateEndpoints`, `privateDns`, `namingObserved`, `quotas`, `architectureConstraints`. See
proposal.md - Why for the motivation. This design covers a new, separate tool that reads that
JSON and renders it as Markdown; it does not touch the discovery scripts at all.

## Goals / Non-Goals

**Goals:**
- Turn an existing discovery JSON file into a Markdown report an architect can read directly
  (in a PR, wiki, or terminal) without cross-referencing raw JSON.
- Flag concrete risks/gaps (unregistered providers, near-exhausted quotas, missing hub VNet) up
  front, not buried in per-section detail.
- Work as a pure, offline transform: no Azure calls, no dependency on `az` being installed or
  authenticated.

**Non-Goals:**
- Not a replacement for the discovery scripts' JSON output — the JSON remains the canonical,
  machine-readable artifact; the Markdown report is a derived, human-facing view.
- Not a general-purpose JSON-to-Markdown templating engine — the section layout and risk rules
  are purpose-built for this discovery schema, not configurable beyond the quota threshold.
- Not implementing new discovery logic or new top-level JSON sections; it only reads sections
  the discovery scripts already produce (per the archived `platform-readiness-discovery` and
  `subscription-discovery` specs).

## Decisions

- **Language: Python 3.** The discovery scripts are deliberately duplicated in bash and
  PowerShell so operators can run discovery from either shell without a language runtime beyond
  `az` + `jq` or `az` + PowerShell. This tool has no such constraint — it never touches Azure —
  so duplicating it in two languages would add maintenance cost for no user-facing benefit.
  Python 3 is chosen because it's commonly available, has a standard-library `json` module (no
  new dependency for parsing), and makes the risk-flagging logic (ratio comparisons, `None`
  checks) far more readable than an equivalent `jq` or PowerShell script. Alternative considered:
  a `jq` template invoked from a thin bash wrapper — rejected because non-trivial Markdown
  generation in raw `jq` is hard to read/maintain compared to Python string templating.
- **Single script, `scripts/generate-readiness-report.py`, not integrated into the discovery
  scripts.** Keeping report generation as a separate, later step (input: JSON path, output:
  Markdown) preserves the discovery scripts' existing single-responsibility (collect and emit
  JSON) and lets the report be regenerated repeatedly, with a different quota threshold, without
  re-running any `az` calls. Alternative considered: add a `--report` flag to the discovery
  scripts themselves — rejected because it would couple report formatting concerns to the
  bash/PowerShell discovery logic, which would then need to be duplicated in two languages.
- **Missing sections are noted, not fatal.** Discovery JSON files may predate a given section
  (e.g. output generated before `rbac`/`providers`/`privateEndpoints`/`privateDns` existed, or
  before `quotas` held real data). The report SHALL render what's present and label absent
  sections rather than fail outright, so older discovery output remains usable.
- **Risk thresholds are best-effort heuristics, matching the discovery scripts' own posture.**
  The quota usage threshold (default 80%) is a starting heuristic, not a hard guarantee of
  capacity; it's documented as such in the report itself, consistent with how the discovery
  scripts already label `namingObserved` and `policy.definitionsSimplified` as best-effort.

## Risks / Trade-offs

- [Risk] Report content can drift from the discovery JSON schema if a future discovery change
  adds/renames a top-level section without updating this tool. → Mitigation: the report already
  tolerates missing sections gracefully (see Decisions); a schema-drift bug would only mean a
  new section isn't yet summarized, not that report generation breaks. Extending the report for
  a new section is a small, additive change.
- [Risk] A fixed default risk threshold (80% quota usage) may not suit every subscription's risk
  tolerance. → Mitigation: exposed as a command-line option so callers can tune it per review
  without editing the script.
- [Risk] Python may not be installed in every environment that has `az`/`jq`/PowerShell
  available. → Mitigation: Python 3 is a very common baseline (already used in this repo's own
  verification tooling this session); documented as a prerequisite in `scripts/README.md`
  alongside the existing `az`/`jq`/PowerShell prerequisites.
