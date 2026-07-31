---
name: gherkin
description: (OPTIONAL / opt-in for now) Convert tasks.md user stories into pruned Gherkin feature files under specs/<feature>/acceptance/. Run after human gate 1 (spec/tasks approved), only when acceptance tests are wanted.
---

> **Opt-in stage.** Acceptance tests (Gherkin + Reqnroll) are optional until introduced project-wide. Run this only when the user asks for acceptance coverage; otherwise skip straight from human gate 1 to `/implement`. See the Acceptance-tests policy in `.cursor/rules/agent-pipeline.mdc`.

## User Input

```text
$ARGUMENTS
```

## Prerequisites

- Human gate 1 passed (`spec.md`, `plan.md`, `tasks.md` reviewed)
- Run from the repository root

Resolve feature directory:

1. Run `.specify/scripts/powershell/check-prerequisites.ps1 -Json -RequireTasks -IncludeTasks` and parse `FEATURE_DIR`
2. If that fails, use `$ARGUMENTS` as feature path or `specs/` subdirectory

## Goal

Emit executable Gherkin specifications only — no step definitions, no production code.

## Inputs

Read from `FEATURE_DIR`:

- `spec.md` — user stories, acceptance scenarios (Given/When/Then)
- `tasks.md` — task IDs, user story phases (P1, P2, …)

## Output

Create or update `FEATURE_DIR/acceptance/<story-slug>.feature`:

- One file per user story (P1, P2, P3, …)
- File name: kebab-case from story title (e.g. `trace-workbook-upload.feature`)

## Generation Rules

1. **Feature header:** `Feature:` line matches user story title; add `@P1` / `@P2` tag from priority
2. **Scenarios:** Convert acceptance criteria from `spec.md`; merge duplicates across criteria
3. **Prune:**
   - Drop implementation detail (class names, SDK types, connection strings)
   - Keep domain language (upload, queue, trace, tracking identifier)
   - One scenario per distinct behavior; combine redundant Given/When setup
4. **Traceability:** First line of each scenario is a comment with task ID: `# T012`
5. **Edge cases:** Include edge cases from `spec.md` as separate scenarios when testable
6. **Background:** Use `Background:` only when 3+ scenarios share identical Given steps

## Do Not

- Generate C# step definitions or bindings
- Reference Reqnroll attributes or test project paths in `.feature` files
- Add scenarios not traceable to `spec.md` or `tasks.md`

## Validation

Before finishing:

- [ ] Every P-priority user story has a `.feature` file
- [ ] Each scenario has a `# T###` comment
- [ ] No scenario exceeds 8 steps
- [ ] Wording matches `spec.md` acceptance criteria

## Handoff

Tell the user to complete **human gate 2** (spot-check Gherkin), then run `/implement`.

Reference: the `agent-pipeline` rule (`.cursor/rules/agent-pipeline.mdc`)
