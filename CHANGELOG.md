# Changelog

Notable changes to `dotnet-agent-harness`. The version here is written into a
consuming repo's `harness.yml` as `harnessVersion`, so an install reports
the old and new versions rather than overwriting silently.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [semantic versioning](https://semver.org/), where a **major** bump
means a consuming repo's gates may start failing on code that previously passed.

## [0.4.0] — 2026-08-08

### Added

- The `guard.ps1` PreToolUse hook now blocks **deleting a protected branch via
  push**, closing a gap where only force-pushes were caught. A delete is refused
  whether expressed as `--delete`/`-d` (including any unique abbreviation Git
  accepts — `--de` through `--delete` — and clustered forms such as `-fd`) or as
  an empty-source `:dst` refspec (`git push origin :main`, `:refs/heads/main`,
  `+:main`). Detection is per-refspec, so deleting a task branch alongside a
  plain push to a protected branch in one command is still allowed, as are
  fast-forward pushes, `--no-delete`, and `--dry-run`.

### Breaking

- **Solution resolution now requires a unique repo-root candidate when multiple
  solutions exist.** A repo with solutions only at depth > 0 and no unique
  root-level `.sln`/`.slnx` (e.g. `src/App.sln` + `tools/Other.sln`) previously
  built `src/App.sln` silently in the analyzer and complexity gates; it now
  refuses with remediation. Fix: `solution: src/App.sln` in `harness.yml`.

### Fixed

- **All gates and callers now use one solution resolver (`Resolve-Solution`).**
  Three functions previously resolved solutions independently with different
  policies. `Resolve-BuildTarget` picked the shallowest candidate silently;
  `Get-TestProjects` refused on ambiguity; `Get-HarnessConfig` refused on
  ambiguity eagerly at config load, breaking `new-task-branch.ps1` and
  `install.ps1` in any repo with multiple solutions and no `solution:` set —
  even though neither command needs a solution.
- **`solution:` in `harness.yml` is now honoured by every gate.** The analyzer,
  complexity, and InspectCode gates previously ignored it, using their own
  discovery instead.
- **Candidate scans now exclude `bin/`, `obj/`, `node_modules/`, and
  `artifacts/` everywhere.** `Get-HarnessConfig`'s glob previously lacked this
  filter, so a stale `.sln` copied into `artifacts/` could trip it.

## [0.3.0] — 2026-08-07

### Breaking

- **Agent tier configuration is now nested by `model` and `effort`.** The old
  scalar Claude and Cursor keys are intentionally rejected instead of silently
  preserving inert configuration. Migrate this:

  ```yaml
  agents:
    tiers:
      fast:
        claude: inherit
        cursor: auto
  ```

  to this:

  ```yaml
  agents:
    tiers:
      fast:
        claude:
          model: claude-haiku-4-5-20251001
          effort: low
        cursor:
          model: gpt-5.6-luna
          effort: low
        codex:
          model: gpt-5.6-terra
          effort: low
  ```

  To undo the new cheap-model default for any host, set both of that host's
  fields to `inherit`.

### Added

- Seven tiered named agents now install in every host's native discovery format:
  `.claude/agents/*.md`, `.cursor/agents/*.md`, and `.codex/agents/*.toml`.
- `code-scout` handles bounded read-only searches whose conclusion is much
  smaller than their input.
- `edit-applier` handles one fully specified mechanical edit over an exclusive
  file set, with a stop-and-report contract for ambiguity or partial work.
- An always-on cost-aware delegation rule governs cheap mid-task errands, the
  cases that stay inline, semantic-verdict prohibitions, and one-strike fallback.

### Changed

- `fast` profiles default to verified cheaper models at low effort on Claude
  Code, Cursor, and Codex. `balanced` and `deep` continue to inherit.
- Read-only profiles render native controls per host: Claude Code plan mode,
  Cursor `readonly`, and Codex's read-only sandbox.
- Generated agents use marker-based per-file ownership. Reinstallations refresh
  marked files, preserve unrelated agents, report unmarked same-name collisions,
  and adopt only byte-exact 0.2.0 Claude profiles during migration.
- Codex skill invocations inside generated agent instructions use `$name` syntax.

## [0.2.0] — 2026-08-05

Everything here came from installing `0.1.0` into two real projects. The fixture
had proved the gates against code written to be caught by them; the first
contact with repositories that already had history, a `CLAUDE.md`, and more than
one test assembly found every defect listed below, none of which the fixture
could have surfaced.

### Breaking

The number stays below 1.0, but read this section before upgrading: **a caller
that treats any non-zero exit as failure will break.**

No gate reports FAIL on code it previously passed. What changed is that gates
which verified *nothing* now say so — exit `2` instead of a claimed pass — and
one scan that examined nothing now exits `1`. Whether that is "major" depends
entirely on how you consume the exit codes, so it is written out rather than
argued about: if your pipeline fails on non-zero, this release breaks it until
you handle `2`.

- **A gate with nothing to verify now exits `2` (SKIPPED), not `0`.** The three
  diff-scoped gates returned `0` when no `.cs` file had changed, so the first
  run after an install reported green over a codebase no gate had read. Every
  document in this repo already said 2 was the answer; only the code disagreed.
  **A caller treating any non-zero result as failure will now see routine no-op
  runs as failures** — read `2` as "verified nothing" and re-run with `-All`
  when verification is what you want.
- **The property gate runs one test project per invocation.** It used to run the
  whole solution and classify the interleaved output, which cannot distinguish
  "this assembly had no matching tests" from "that assembly died before
  reporting". Costs one `dotnet test` per test project.
- **`run-property-tests.ps1 -Project` no longer accepts a solution.** Name a
  `.csproj`, or omit it to run every discovered test project.
- **A vulnerable-package scan that enumerated no projects exits `1`**, not `0`
  with "no vulnerable packages".

### Fixed

- Property tests were reported as SKIPPED on any solution with more than one
  test assembly — the ordinary shape of a .NET solution, so the gate was
  effectively dead for most consumers
- `CLAUDE.md` `@imports` were never installed into a repo that already had a
  `CLAUDE.md`, so **no harness rule loaded on Claude Code at all** — silently,
  because a missing import is indistinguishable from a quiet rule
- The constitution was documented as rendered by `install.ps1` and was rendered
  by nothing
- `.specify/extensions.yml` was overwritten unconditionally, silently disabling
  any registered Spec Kit extension
- The `after_refactor` hook could never fire — Spec Kit emits no such event
- The Gherkin mutation gate crashed on the last scenario of every feature file,
  ran tests without rebuilding the mutated feature, and counted a failed run as
  a killed mutant
- The vulnerable-package gate crashed on any solution containing a project with
  no advisories, hiding 44 live advisories across two projects
- `install.ps1` crashed on the upgrade path when `harness.yml` had no version
  stamp
- Gates never found `.editorconfig` on Linux or macOS
- `/code-review`'s position in the pipeline, the failure-routing table, and the
  human-gate time budgets, all lost when the harness was extracted

### Added

- Five self-test suites — secret scanning, the Spec Kit coupling, the installed
  artifacts, the Gherkin mutation logic and the gate exit contract — bringing the
  total to eight. Each was verified to fail against the code it replaced, because
  a test written after the fix proves only that the fix is self-consistent
- An acceptance-test fixture proving the Gherkin mutation gate in both
  directions, retiring one of the two stated limitations
- `AVAILABLE` install status for templates that ship but are deliberately not
  copied

## [0.1.0] — 2026-07-31

First release. Extracted from a private, gitignored Cursor setup and generalised
to run on both Cursor and Claude Code with no paid service.

### The pipeline
- 11 stages from issue to PR, with three human approval gates
- Mandatory `/grill-with-docs` alignment before any spec is written
- Chains into [Spec Kit](https://github.com/github/spec-kit) `0.8.14` via a
  15-line `extensions.yml` — the entire coupling

### The gates
Six checks, all running locally after `dotnet tool restore`, none needing an
account:

| Gate | Default |
|---|---|
| Roslyn analyzers, incl. the security families | warning+ |
| Cyclomatic complexity | ≤ 15 implementing, ≤ 6 at refactor |
| InspectCode inspections and duplication | zero on changed files |
| Mutation score | ≥ 80% |
| Property tests | required for pure logic |
| Vulnerable packages | zero, incl. transitive |

- **Exit contract: 0 = pass, 1 = fail, 2 = SKIPPED.** A gate that verified
  nothing reports 2 and is never folded into a green verdict.
- `AnalysisMode=All` enables CA2100 / CA3xxx / CA5xxx, which are off by default —
  this is what replaces the local half of a hosted static-analysis service.
- A gate whose analyzer is not wired exits 1 with remediation rather than
  reporting a pass it did not earn.

### Configuration
- `harness.yml` is the entire config surface; thresholds live there and are
  rendered into `CodeMetricsConfig.txt`, `stryker-config.json`, the
  `.editorconfig` severities, and the constitution's Verification Gates article
- Parsed by a strict subset reader — **unknown keys are a hard error**, so a
  typo cannot silently revert a threshold to its default

### Both platforms
- 25 skills and 5 agents in `.claude/`, read natively by Cursor and Claude Code
- Vendored .NET rules load by glob on both: `globs:` for Cursor,
  generated `paths:` for Claude Code
- Only five files differ between platforms — the adapters

### Verification
- `fixtures/BadCode` carries one deliberate violation per gate; CI asserts every
  gate exits non-zero on the broken state and zero on the fixed one
- Self-tests for the guard hook (23 checks) and the config parser (14 checks)
- The guard's suite includes the escaped-quote payload that defeats a
  `grep`-based hook

### Known limitations
- The vulnerable-package gate is proven against a canned advisory document, not
  a real CVE — see `fixtures/BadCode/README.md`
- Gherkin mutation has no fixture; acceptance tests are opt-in and the gate
  reports SKIPPED when no `.feature` files exist
- Agent frontmatter carries `readonly:` (Cursor) and `tools:` (Claude Code);
  neither platform documents ignoring the other's key. See the pre-publish
  checklist in `CONTRIBUTING.md`

[0.1.0]: https://github.com/lamuniercosta/dotnet-agent-harness/releases/tag/v0.1.0
[0.2.0]: https://github.com/lamuniercosta/dotnet-agent-harness/releases/tag/v0.2.0
[0.3.0]: https://github.com/lamuniercosta/dotnet-agent-harness/releases/tag/v0.3.0
[0.4.0]: https://github.com/lamuniercosta/dotnet-agent-harness/releases/tag/v0.4.0
