# AGENTS.md

Guidance for AI coding agents working in this repository.

## Spec-driven workflow (OpenSpec)

This project uses [OpenSpec](https://github.com/Fission-AI/OpenSpec). Specs are the source of truth for behavior; code follows them.

**Before writing code for any non-trivial change, create an OpenSpec change.** Non-trivial means: a new capability, a change to observable behavior, a new external dependency, or anything touching a deployed resource's contract.

| Intent | Do this |
|---|---|
| New feature or behavior change | `/opsx-propose` — creates `proposal.md`, `specs/`, `design.md`, `tasks.md` |
| Implement an approved change | `/opsx-apply` — work `tasks.md` top to bottom, checking off as you go |
| Finish and fold specs into the baseline | `/opsx-archive` |
| Think through an idea first | `/opsx-explore` |

The equivalent skills in `.github/skills/` carry the full instructions — read the relevant one before acting.

Useful commands:

```bash
openspec list                         # active changes
openspec list --specs                 # baseline capabilities
openspec status --change "<name>"     # artifact progress
openspec validate "<name>" --strict   # validate before implementing
openspec show "<name>"
```

### GitHub issues track OpenSpec changes

Every change proposal gets a GitHub issue, and the issue closes when the change is archived. The issue is the outward-facing view of the change; the `openspec/changes/<name>/` folder is the detail.

- `/opsx-propose` creates the issue with the `openspec` label and records it in `github-issue.md` inside the change folder.
- Implementation commits reference it with `Refs #N`.
- `/opsx-archive` closes it — but **only if all tasks are checked**. A half-done change must not look finished on the issue tracker.
- An issue is closed when the work is *done*, not when it is deferred. If work is blocked on an external dependency, leave it open.

> **Note:** `openspec update` overwrites the files in `.github/skills/`, which silently drops this customization. After running it, verify `gh issue create` is still in the propose skill and `gh issue close` is still in the archive skill, and restore them if not.

**Rules**
- Do not start implementing until `openspec validate <name> --strict` passes.
- Baseline specs in `openspec/specs/` use `## Purpose` + `## Requirements`. Change deltas use `## ADDED/MODIFIED/REMOVED Requirements`. Archiving converts between them — if `openspec list --specs` shows `requirements 0`, the conversion did not happen and the spec is not being parsed.
- Specs describe *observable behavior*, not implementation. No class names, no library choices, no step-by-step plans — those belong in `design.md`.
- Scenarios need exactly four hashes (`#### Scenario:`). Three fails silently.
- Keep `tasks.md` checkboxes current as you implement; that file is the progress record.
- Bug fixes, typos, and pure refactors do not need a change proposal.

Established baseline specs live in `openspec/specs/`. Read the relevant one before modifying behavior it covers.

## Project shape

_TBD — this repository is still empty. Fill in once the codebase takes shape: language/stack, directory layout, and how deployable units (e.g. Bicep/Terraform modules) map to the pipeline or system being built._

## Conventions

_TBD — capture non-obvious, repo-specific rules here as they emerge (e.g. how resources must be added/wired, identity/auth patterns, anything that fails silently if done wrong)._

## Commands

_TBD — record the actual build/test/deploy commands once the toolchain (Bicep, Terraform, azd, etc.) is chosen._

## Gotchas

_TBD — document surprising behaviors discovered while working in this repo._
