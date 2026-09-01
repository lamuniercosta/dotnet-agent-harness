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
| Architect done, review not clean | 9 | `/code-review` → `/remediate` until clean (later rounds: fix-diff only) |
| Review clean | 10 | rebase → `/ship-review` → open the PR (`/architect` once on loop close first, if remediations accumulated) |
| `gh pr view`: open PR with unaddressed external feedback | 11 | `/address-pr-review` |
| `gh pr view`: open PR with no blocking external feedback | 12 | human gate 3 — merge |

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
