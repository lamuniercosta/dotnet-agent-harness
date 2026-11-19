---
name: pipeline
description: Orchestrator for the Agent Development Pipeline — reports current stage, next command, and gate checklist.
---

## User Input

```text
$ARGUMENTS
```

## Goal

Determine where the active feature is in the pipeline and recommend the next command.

## Stage Detection

Run `.specify/scripts/powershell/check-prerequisites.ps1 -Json` when possible. Inspect `FEATURE_DIR`:

Stage numbers match the `agent-pipeline` rule. Keep them in step with it — a table
that renumbers itself is how a stage reference becomes unreadable and gets deleted
rather than corrected.

Past stage 10 the artifacts live on GitHub, not the filesystem. Detect 11 and 12
with `gh pr view` on the current branch.

| Condition | Stage | Next command |
|---|---|---|
| No branch / no `brief.md` | 0 → 1 | `/task <id> [type]` → `/grill-with-docs` (mandatory) |
| `brief.md` exists, no `spec.md` | 2 | `/speckit-specify` |
| `spec.md` exists, no `plan.md` | 2 | `/speckit-clarify` → `/speckit-plan` |
| `plan.md` exists, no `tasks.md` | 2 | `/speckit-tasks` |
| `tasks.md` exists | 2 → 3 | `/speckit-analyze` → human gate 1 → `/implement` *(or opt-in `/gherkin` first)* |
| Acceptance `.feature` exist, no bindings | 4 → 5 | *(only if opted in)* Human gate 2 → `/implement` |
| Code exists, CA1502 above `gates.complexity.refactor` on changed files | 7 | `/refactor` |
| Refactor done, mutation not run | 8 | `/architect` |
| Architect done, review not clean | 9 | `/code-review` → `/remediate` until clean (later rounds: `Explicit diff range: ROUND_BASE...HEAD`) |
| Review clean | 10 | rebase → `/ship-review` → open the PR (`/architect` once on loop close first, if remediations accumulated) |
| `gh pr view`: open PR with unaddressed external feedback | 11 | `/address-pr-review` |
| `gh pr view`: open PR with no blocking external feedback | 12 | human gate 3 — merge |

### Size S path

A ticket tagged `size:S` (mechanical, at most 5 files) skips stages 2 to 5. It gets no `spec.md`, `plan.md`, `tasks.md`, `checklists/`, `DRAFTING_RECEIPT.md`, Gherkin, plan challenge or Gate 1, and no `/grill-with-docs` session. Its only artifacts are:

- a short `specs/<feature>/brief.md` of at most 40 lines (what changes, closing bar, test plan), written from the ticket text before the build; and
- the PR description.

| Condition (S ticket) | Stage | Next command |
|---|---|---|
| No `brief.md` | 1 | write the short `brief.md` from the ticket text |
| `brief.md` exists, no code | 6 | `/implement` directly; do not run `/speckit-specify`, `/speckit-plan`, `/speckit-tasks` or `/speckit-analyze` |
| Code exists | 7 onward | same rows as the main table, from stage 7 |

Do not run `check-prerequisites.ps1 -RequireTasks` or `setup-tasks.ps1` on an S ticket: both exit 1 without `plan.md`. M and L tickets keep the full table above, unchanged. Size comes from the ticket's `size:` tag; with no tag, get it settled before choosing a path.

Use `$ARGUMENTS` to force a stage check on a specific feature path.

## Output Format

```markdown
## Pipeline Status

**Feature:** {path}
**Stage:** {number} — {name}
**Next:** `{command}`

### Pending gates
- [ ] {gate checklist items}

### Quick commands
{relevant scripts for the current stage, per the agent-pipeline rule}
```

## Reference

Full pipeline: the `agent-pipeline` rule (`.cursor/rules/agent-pipeline.mdc`)

Extension hooks: `.specify/extensions.yml` at the repository root
