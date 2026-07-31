---
name: refactor
description: Refactor changed code down to the refactor complexity threshold, remove duplication, add FsCheck property tests. Run after /implement.
---

## User Input

```text
$ARGUMENTS
```

## Prerequisites

- `/implement` complete — all tests green
- Read the `agent-pipeline` rule (`.cursor/rules/agent-pipeline.mdc`) for stage order and handoff rules

## Goals

1. **Cyclomatic complexity at or under `gates.complexity.refactor`** in `harness.yml` (default **6**) on all `.cs` files changed in the feature branch
2. **Remove duplication** — address InspectCode `DuplicatedCode`; extract helpers, use early returns
3. **Property tests** — add FsCheck tests for pure/domain logic (validators, mappers, propagators)

## Refactor Techniques

- Extract private methods when complexity exceeds 6
- Guard clauses and early returns
- Replace nested conditionals with polymorphism only when simpler alternative rejected
- Do not add comments unless user requested

## Property Test Rules

- Location: `tests/<Project>.UnitTests/PropertyTests/`
- Trait: `[Trait("Category", "Property")]`
- Target pure functions first: `MessageTracePropagator`, validators, mappers
- Use `FsCheck.Xunit.Property` or `Property` attribute

## Gate Scripts

Run from repository root in order:

```powershell
./scripts/run-cyclomatic-complexity.ps1 -Threshold 6
./scripts/run-roslyn-analyzers.ps1
./scripts/run-jetbrains-inspectcode.ps1
./scripts/run-property-tests.ps1
dotnet test
```

Fix every failure before proceeding. Re-run gates until all pass.

## Exit Criteria

- [ ] No methods exceed complexity 6 on changed files
- [ ] Roslyn analyzers clean on changed files
- [ ] InspectCode WARNING+ clean on changed files
- [ ] Property tests pass
- [ ] Full `dotnet test` green

## Handoff

On success, output:

```
## Extension Hooks

**Automatic Hook**: pipeline
Executing: `/architect`
EXECUTE_COMMAND: architect
```

Or tell user to run `/architect` if hook executor is unavailable.

## Do Not

- Change behavior covered by passing tests without updating tests
- Suppress CA1502 unless generated code with justification
- Skip property tests for new pure functions in changed files
