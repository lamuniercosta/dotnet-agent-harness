---
name: architect
description: Run Stryker mutation testing, Gherkin mutation, coverage gap check, and full test suite. Route survivors back to gherkin/implement/refactor.
---

## User Input

```text
$ARGUMENTS
```

## Prerequisites

- `/refactor` complete
- Read the `agent-pipeline` rule (`.cursor/rules/agent-pipeline.mdc`) for stage order and handoff rules

## Goals

1. **Code mutation:** Stryker.NET on changed production assemblies — mutation score at or above `gates.mutation.threshold` in `harness.yml` (default **80%**)
2. **Gherkin mutation** *(optional — only if acceptance tests exist)*: `./scripts/run-gherkin-mutation.ps1` — no survivors. Acceptance tests are opt-in for now; skip this goal when `specs/<feature>/acceptance/*.feature` does not exist.
3. **Coverage:** Address uncovered branches in changed production files (coverlet)
4. **Full suite:** `dotnet test` on entire solution

## Gate Scripts

Run from repository root:

```powershell
dotnet stryker --config-file stryker-config.json
dotnet test --collect:"XPlat Code Coverage"
dotnet test
# Only when acceptance tests exist (opt-in for now):
./scripts/run-gherkin-mutation.ps1
```

Stryker requires `dotnet tool restore` (see `dotnet-tools.json`).

## Mutation Score

- Threshold: `gates.mutation.threshold` in `harness.yml` (default **80%**) on mutated code in scope
- Scope: the assemblies listed in `stryker-config.json` (see `stryker-config.json`)
- If score below threshold: strengthen unit/property tests or simplify code — re-run Stryker

## Gherkin Survivors *(only when acceptance tests exist)*

If `run-gherkin-mutation.ps1` reports survivors:

| Survivor type | Route to |
|---|---|
| Scenario still passes after Then mutation | `/implement` — strengthen bindings |
| Missing scenario coverage | `/gherkin` — add scenario |
| Assertion too weak | `/refactor` — add property test |

Re-enter architect after fixes.

## Coverage Gaps

For changed `.cs` files with uncovered branches:

- Add unit or property tests in `/implement` scope
- Do not exclude lines from coverage without justification

## Exit Criteria

- [ ] Stryker mutation score at or above `gates.mutation.threshold` (default 80%)
- [ ] Full `dotnet test` green
- [ ] No new InspectCode WARNING+ on changed files
- [ ] Gherkin mutation: zero survivors *(only if acceptance tests exist — opt-in for now)*

## Handoff

Tell user to complete **human gate 3** (spot-check code) and open PR.

On failure loop, specify which skill to re-run and what failed.
