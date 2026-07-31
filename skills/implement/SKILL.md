---
name: implement
description: Implement feature from tasks.md with xUnit tests and production code (plus Reqnroll acceptance bindings when acceptance tests exist). TDD optional — all tests must pass before handoff. Run after human gate 1 (or human gate 2 when acceptance tests were generated).
---

## User Input

```text
$ARGUMENTS
```

## Prerequisites

- Human gate 1 passed (spec/plan/tasks approved). If acceptance tests were generated (opt-in), Human gate 2 (Gherkin spot-checked) also passed
- `FEATURE_DIR/acceptance/*.feature` exists **only if** the optional Gherkin stage ran — acceptance tests are opt-in for now
- Read the `agent-pipeline` rule (`.cursor/rules/agent-pipeline.mdc`) for stage order and handoff rules

Resolve feature directory via `.specify/scripts/powershell/check-prerequisites.ps1 -Json -RequireTasks -IncludeTasks`.

## Goal

Implement the feature until all tests pass. **Test-first ordering is not required** — write acceptance bindings, unit tests, and production code in any order, but complete all before handoff.

## Required Reads

- `tasks.md` — execution order, task IDs, file paths
- `plan.md` — architecture, tech stack, layer rules
- `spec.md` — acceptance intent
- `acceptance/*.feature` — executable scenarios *(only if the optional Gherkin stage ran)*
- `.specify/memory/constitution.md` — non-negotiable constraints
- `contracts/` and `quickstart.md` if present

## Implementation Targets

| Artifact | Location |
|---|---|
| Step definitions | `tests/<Project>.AcceptanceTests/Steps/` |
| Unit tests | `tests/<Project>.UnitTests/` |
| Integration tests | `tests/<Project>.IntegrationTests/` |
| Production code | `src/` per plan.md |

Feature files are synced from `specs/**/acceptance/` into `Features/` at build time. The AcceptanceTests project excludes specs paths from Reqnroll default glob:

```xml
<ReqnrollFeatureFiles Remove="..\..\specs\**\*.feature" />
```

## Execution Order (flexible)

1. Reqnroll `[Binding]` step classes for each `.feature` scenario *(only if acceptance tests exist — opt-in)*
2. xUnit unit tests for business logic, validators, propagators, mappers
3. Integration tests for boundaries (Mongo, Service Bus, HTTP)
4. Production code per `tasks.md` phases
5. Mark completed tasks `[X]` in `tasks.md`

Reuse existing patterns: NSubstitute, FluentAssertions, WireMock, Testcontainers, WebApplicationFactory.

## Mid-Stage Gates

After materially editing `.cs` files, run from repo root:

```powershell
./scripts/run-jetbrains-inspectcode.ps1
./scripts/run-roslyn-analyzers.ps1
./scripts/run-cyclomatic-complexity.ps1
dotnet test
```

Interim complexity threshold is **15** (default from `CodeMetricsConfig.txt`).

## Exit Criteria

- [ ] All tasks in `tasks.md` marked `[X]`
- [ ] `dotnet test` passes (Unit + Integration; Acceptance too, if acceptance tests exist)
- [ ] InspectCode clean at WARNING+
- [ ] Roslyn analyzers clean (no CA/IDE warnings on changed files)
- [ ] CA1502 at or under `gates.complexity.implement` in `harness.yml` (default 15) on changed files

## Handoff

On success, `extensions.yml` triggers `/refactor` via `after_implement` hook. If hook does not run automatically, tell user to run `/refactor`.

Do not run refactor or architect steps in this skill.
