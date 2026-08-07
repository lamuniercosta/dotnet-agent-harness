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

| Condition | Stage | Next command |
|---|---|---|
| No branch / no `brief.md` | 0 → 1 | `/task <id> [type]` → `/grill-with-docs` (mandatory) |
| `brief.md` exists, no `spec.md` | 2 | `/speckit-specify` |
| `spec.md` exists, no `plan.md` | 2 | `/speckit-clarify` → `/speckit-plan` |
| `plan.md` exists, no `tasks.md` | 2 | `/speckit-tasks` |
| `tasks.md` exists | 2 → 3 | `/speckit-analyze` → human gate 1 → `/implement` *(or opt-in `/gherkin` first)* |
| Acceptance `.feature` exist, no bindings | 4 → 5 | *(only if opted in)* Human gate 2 → `/implement` |
| Code exists, CA1502 above `gates.complexity.refactor` on changed files | 7 | `/refactor` |
| Refactor done, mutation not run | 7 → 8 | `/code-review` *(non-gated, recommended)* → `/architect` |
| All gates pass | 9 → 10 | Human gate 3 → `/ship-review` → rebase → PR |

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
