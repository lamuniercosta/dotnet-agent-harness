# Development instructions

This repository uses **dotnet-agent-harness**. The pipeline, gates, and conventions
below are enforced by scripts, not by good intentions.

Both platforms load these rules natively. The always-on ones are imported below;
the file-scoped ones live in `.claude/rules/vendor/` with `paths:` frontmatter and
load automatically when you touch a matching file.

## Always-on rules

Imported from `.cursor/rules/` deliberately. These ten exist in exactly one place:
Cursor requires them at that path to load them, and an `@import` resolves any
relative path, so copying them into `.claude/rules/` would create two files that
drift. One file, one home, both platforms.

If you are working Claude-only, do not delete `.cursor/` — every import below
resolves into it.

@.cursor/rules/agent-pipeline.mdc
@.cursor/rules/github-workflow.mdc
@.cursor/rules/coding-conventions.mdc
@.cursor/rules/documentation-sources.mdc
@.cursor/rules/cyclomatic-complexity.mdc
@.cursor/rules/roslyn-analyzers.mdc
@.cursor/rules/jetbrains-inspections.mdc
@.cursor/rules/refactor-gate.mdc
@.cursor/rules/architect-gate.mdc
@.cursor/rules/readme-maintenance.mdc

## File-scoped rules

`.claude/rules/vendor/` holds eight .NET reference rules with `paths:` frontmatter,
so they load only when you touch a matching file — `.csproj`, workflow YAML, test
projects, and so on. Nothing to invoke; they arrive when relevant.

They are third-party reference (see `NOTICE`) and rank **below** this repo's own
config, the always-on rules above, and the pattern in neighbouring code. Where one
contradicts the repo, the repo wins — say so rather than following it silently.

## Configuration

`harness.yml` at the repo root is the entire configuration surface — thresholds,
base branch, tracker, agent model tiers. It is the **single source of truth**:
`CodeMetricsConfig.txt`, `stryker-config.json`, and the `.editorconfig` gate
severities are all rendered from it by `install.ps1` on every run.

`.specify/memory/constitution.md` is rendered **only when absent**. Once it
exists it is the project's own law and no install touches it again — so if it
quotes a threshold, that number is yours to keep in step with `harness.yml`.

Never hardcode a threshold, and never edit a generated file — the next install
overwrites it.

## Verification commands

```powershell
./scripts/run-roslyn-analyzers.ps1          # CA/IDE/VSTHRD + the security families
./scripts/run-cyclomatic-complexity.ps1     # -Threshold 6 at the refactor gate
./scripts/run-jetbrains-inspectcode.ps1     # a different engine; catches duplication
./scripts/run-property-tests.ps1
./scripts/run-vulnerable-packages.ps1
dotnet test
dotnet stryker                              # minutes-expensive; pre-PR only
```

`-BaseRef`/`-Files`/`-All` exist **only on the three analyzer gates** — roslyn-analyzers,
cyclomatic-complexity, jetbrains-inspectcode. There, no args analyses changed files vs
the base branch; `-Files "a.cs","b.cs"` an explicit set; `-All` the whole solution. The
rest take their own scope instead: `run-property-tests.ps1 -Project -Category`,
`run-gherkin-mutation.ps1 -Project -SpecsPath`, `run-vulnerable-packages.ps1 -Severity
-IncludeTransitive`. Passing `-All` to one of those exits 1 on a parameter-binding
error — a failure to launch, not a failed scan; do not report it as a red gate.

**Exit 0 = pass, 1 = fail, 2 = SKIPPED.** A SKIPPED gate verified nothing and is never folded into a green verdict.

**A gate that could not run has not passed.** The scripts enforce this themselves:
if the analyzer they depend on is not wired, they exit 1 with remediation rather
than reporting a pass they did not earn. Report an unrunnable gate as SKIP, never
fold it into a green verdict, and never substitute plain `dotnet build`.

## Agents

Five agents live in `.claude/agents/` and are read natively by both Cursor and
Claude Code. Delegate to them rather than running noisy work inline:

- `gate-runner` (read-only) — runs the gates, returns `file:line` + cause
- `test-writer` — the only agent that writes files; stays inside `tests/`
- `mutation-analyst` (read-only) — triages Stryker survivors
- `code-reviewer` (read-only) — one named axis per call: Risk, Standards, or Spec
- `security-reviewer` (read-only) — supply chain, authz, injection, data exposure

They default to `inherit`/`auto` models, so the pipeline costs nothing beyond the
editor subscription. Pin per tier in `harness.yml` if you want to.

## Non-negotiables

- `TimeProvider` for time, injected seeded `Random` for randomness. `DateTime.Now`
  is in `BannedSymbols.txt` and **fails the build** (RS0030 is an error).
- A surviving mutant is a missing test. Fix the test, never the threshold.
- Match the repo's existing architecture, assertion library, and mocking library.
  Introducing a second one is a defect.
- No explanatory comments (`// arrange` / `// act` / `// assert` in tests are the
  one exception).
- Never mock the data-access driver for behaviour that depends on real query
  translation or serialisation — use Testcontainers.

## Workflow

1. `/task <issue>` — read the issue, create the branch in its own worktree
   (`<repo>.worktrees/…`, beside the repo); work there, not in the main checkout
2. `/grill-with-docs` — **mandatory**; settles vocabulary in `CONTEXT.md` + ADRs
3. `/speckit-specify` → `/speckit-plan` → `/speckit-tasks` — **human gate 1**
4. `/implement` — TDD, tests must pass
5. `/refactor` — complexity ≤ 6, property tests
6. `/architect` — mutation ≥ threshold — **human gate 3**
7. `/ship-review` → rebase → PR

Consult `/using-agent-skills` at the start of any non-trivial task; it routes to
the right stage and supporting skills.

## Vocabulary

Domain terms live in `CONTEXT.md` — use its canonical terms in code, specs, and
conversation. Architectural decisions live in `docs/adr/`; don't re-litigate them
silently.
