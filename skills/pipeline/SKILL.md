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

| Condition | Stage | Next command |
|---|---|---|
| No branch / no `brief.md` | 0 → 0.5 | `/task <id> [type]` → `/grill-with-docs` (mandatory) |
| `brief.md` exists, no `spec.md` | 1 | `/speckit-specify` |
| `spec.md` exists, no `plan.md` | 1 | `/speckit-clarify` → `/speckit-plan` |
| `plan.md` exists, no `tasks.md` | 1 | `/speckit-tasks` |
| `tasks.md` exists | 1→gate | `/speckit-analyze` → human gate 1 → `/implement` *(or opt-in `/gherkin` first)* |
| Acceptance `.feature` exist, no bindings | 2→gate | *(only if opted in)* Human gate 2 → `/implement` |
| Code exists, CA1502 > 6 on changed files | 4 | `/refactor` |
| Refactor done, mutation not run | 5 | `/architect` |
| All gates pass | Done | Human gate 3 → `/ship-review` → rebase → PR |

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

Extension hooks: [.specify/extensions.yml](../../.specify/extensions.yml)
