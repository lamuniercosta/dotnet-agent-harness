# {{PROJECT_NAME}} Constitution

Ground rules for every feature. The agent reads this before planning; violations found by `/speckit-analyze` block implementation.

## Article I — Spec-Driven Flow

1. No implementation without a spec. The pipeline is fixed: `/task` → `/grill-with-docs` → `/speckit-specify` → `/speckit-plan` → `/speckit-tasks` → `/implement` → `/refactor` → `/architect` → `/ship-review`.
2. Specs use the canonical vocabulary from `CONTEXT.md`. If a spec introduces a term not in the glossary, resolve it into the glossary first.
3. Specs contain no implementation details — requirements from the user's perspective only. Implementation choices belong in `plan.md`.
4. Decisions that are hard to reverse, surprising without context, and the result of a real trade-off are recorded as ADRs in `docs/adr/`. Plans must not contradict existing ADRs; revisiting one requires updating it explicitly.

## Article II — Test-Driven Development

1. All production code is written test-first in a red-green loop: one failing test, minimum code to pass, repeat. Vertical slices — never a batch of tests followed by a batch of code.
2. The first test of any feature is a tracer bullet: one path proven end-to-end before building outward.
3. Tests exercise public interfaces only. A test that breaks when an internal is renamed is a defect in the test.
4. Expected values come from an independent source of truth (spec literal, worked example) — never recomputed the way the code computes them.
5. Refactoring happens only on green.

## Article III — Verification Gates

<!--
  RENDERED SECTION - install.ps1 regenerates this article from harness.yml.
  Edit the thresholds there, not here; a local edit is overwritten on the next
  install and, worse, silently disagrees with what the gates actually enforce.
-->

1. Every task is complete only when `dotnet build` is clean, `dotnet test` is green, and `dotnet format --verify-no-changes` is clean.
2. Cyclomatic complexity is bounded by `gates.complexity.implement` while implementing and by the stricter `gates.complexity.refactor` at the refactor gate. Exceeding it requires refactoring, not suppression; a suppression requires an ADR.
3. Mutation testing runs on changed code before merge, at or above `gates.mutation.threshold`. A surviving mutant means the test is inadequate — **fix the test, never the threshold**. Lowering the number accepts the defect.
4. No known-vulnerable package ships. `gates.vulnerablePackages` is blocking, including transitive dependencies.
5. **A gate that could not run has not passed.** An unrunnable gate is reported as SKIP with remediation; it is never folded into a green verdict.

## Article IV — Architecture

1. Design deep modules: substantial behaviour behind small interfaces. Apply the deletion test to every proposed abstraction.
2. One adapter means a hypothetical seam; two adapters mean a real one. Do not declare an `interface` for a single implementation unless a genuine second adapter (an in-memory fake used across tests, alternative infrastructure) exists or is specified.
3. The interface is the test surface. If testing requires reaching past a module's interface, reshape the module.
4. Domain types carry no persistence concerns. Mapping lives in the infrastructure layer, never as persistence attributes on domain models.
5. Time is injected via `TimeProvider`, randomness via seeded `Random`, outbound HTTP via injected `HttpMessageHandler`. `DateTime.Now`, `DateTime.UtcNow`, and `new Random()` in production code are constitution violations — and `BannedSymbols.txt` makes the first of those a build error.

## Article V — Technology Constraints

1. Runtime: {{TFM_LABEL}} (upgrade only via ADR). Language: C# with nullable reference types enabled and warnings as errors.
2. Local infrastructure runs in Docker (`docker compose up`); integration tests use Testcontainers — never a shared developer database, and never a mocked data-access interface for behaviour that depends on real query translation or serialisation.
3. Adding a dependency is a decision, not a convenience: prefer the platform, then an existing dependency, then a new one. A new runtime dependency in a PR needs a one-line justification.
{{STACK_CONSTRAINTS}}

## Article VI — Conventions

1. Code, identifiers, comments, commit messages, and docs are in English.
2. Structured logging only (`ILogger` with message templates). No `Console.WriteLine` outside entry points and throwaway debug (tagged `[DEBUG-...]`, removed before merge).
3. No secrets or PII in logs, telemetry attributes, exception messages, or API responses. Telemetry attributes are exported more widely than logs and are the most commonly missed.
4. Public API surface changes are breaking-change-reviewed: the contract diff is attached to the task.
5. Commits reference the issue so the tracker links the work, as a suffix — `Add dark mode toggle (#142)`.
6. Match the repo's existing architecture, assertion library, and mocking library. Introducing a second one is a defect, not a preference.

## Governance

Amendments to this constitution are commits like any other: proposed, reviewed, and recorded. When a rule and reality conflict repeatedly, amend the rule or the code — don't accumulate silent exceptions.

Article III is generated from `harness.yml`. To change a threshold, change it there and re-run `install.ps1`; the value then moves in the analyzer config, the gate scripts, and this document together.
