---
name: code-review
description: Review the changes since a fixed point (commit, branch, tag, or merge-base) along three axes — Risk (bugs, security, concurrency, coverage gaps), Standards (does the code follow this repo's documented standards?), and Spec (does it match what the issue/spec asked for?). Scores blast radius, runs a Roslyn pre-pass, fans out to parallel sub-agents, verifies findings, and reports them severity-ranked. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

Three-axis review of the diff between `HEAD` and a fixed point the user supplies:

- **Risk** — is the code correct, safe, and adequately tested?
- **Standards** — does the code conform to this repo's documented coding standards?
- **Spec** — does the code faithfully implement the originating issue / spec?

Each axis runs in an isolated sub-agent when the host supports delegation, with parallel execution when available; otherwise the briefs run inline. Findings are then verified, ranked by severity, and published through the host's native review mechanism, with a Markdown fallback.

## Process

### 1. Pin the fixed point

Whatever the user said is the fixed point — a commit SHA, branch name, tag, `main`, `HEAD~5`, etc. If they didn't specify one, ask for it.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or empty diff should fail here — not inside three parallel sub-agents.

### 2. Score blast radius

Blast radius sets review depth, not line count. A one-line middleware change outranks a 300-line rename. Score each changed file from `git diff --stat`:

| Blast radius | Examples | Depth |
|---|---|---|
| **Critical** | Middleware, auth/authz, DB migrations, shared kernel, CI/CD, crypto, public contracts | Thorough — every code path |
| **High** | Public API changes, message consumers, EF configuration, new module, cache keys | Focused — consumers + behaviour |
| **Medium** | New feature following existing patterns, bug fix, new endpoint | Standard — checklist pass |
| **Low** | Docs, formatting, renames, logging statements | Glance — build + tests pass |

Carry this scoring into every sub-agent prompt: tell them which files are Critical/High so they spend their budget there. If the whole diff is Low, say so and skip the fan-out — a glance plus green tooling is the review.

### 3. Roslyn pre-pass (before reading any file)

If the `cwm-roslyn-navigator` MCP tools are available, run them first — the sub-agents should spend their effort on what Roslyn *can't* see. If the tools are deferred, use the host's tool-discovery mechanism when one is available; otherwise skip this optional pre-pass and continue with the local tooling gate.

```
detect_antipatterns(projectFilter: "<affected project>")   → async void, DateTime.Now, new HttpClient(), broad catch
get_diagnostics(scope: "project", path: "<affected project>") → warnings, nullability
get_test_coverage_map(...)                                  → changed types with no covering test
find_references(symbolName: "<changed public type>")        → consumer count = blast radius evidence
```

**Separate newly introduced findings from pre-existing ones** — only new ones are review findings; mention pre-existing ones once, as context, not as findings against this change.

Also run the tooling gate: `dotnet format --verify-no-changes` and `dotnet build` (with analyzers). If they fail, report that as a single **tooling** line, not as individual review findings.

**Skip anything tooling already enforces.** Don't re-litigate whitespace, analyzer-covered naming, or nullable warnings. The review's value is what static analysis misses.

Pass the pre-pass results into the sub-agent prompts — they have no other access to them.

### 4. Identify the spec source

Look for the originating spec, in this order:

1. **SpecKit artifacts.** If the repo uses SpecKit (`specify-cli`), the spec lives under `specs/<NNN-feature-name>/` — read `spec.md` as the primary spec, and `plan.md` / `tasks.md` for the intended decomposition. Match the feature directory to the branch name (SpecKit branches and spec directories share the `NNN-feature-name` slug).
2. Issue references in the commit messages (`#123`, `Closes #45`, etc.) — fetch via `gh issue view <n>` or the tracker the repo documents.
3. A path the user passed as an argument.
4. A PRD/spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
5. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

### 5. Identify the standards sources

Anything in the repo that documents how code should be written: `CODING_STANDARDS.md`, `CONTRIBUTING.md`, the conventions sections of `CLAUDE.md`/`AGENTS.md`, `.cursor/rules/*.mdc`, `harness.yml` (the gate thresholds), and — .NET-specific — `.editorconfig` (style + analyzer severities), `Directory.Build.props` (`AnalysisLevel`, `AnalysisMode`, `TreatWarningsAsErrors`, analyzer package references), `BannedSymbols.txt`, and any `.globalconfig`.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below — a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation — cap these at **Medium** severity unless the repo documents the rule explicitly.

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Mysterious Name** — a method, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code** — the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together. → in C#, bundle them into a `record` and pass that.
- **Primitive Obsession** — a `string`/`Guid`/`decimal` standing in for a domain concept that deserves its own type. → give the concept its own small type (a `readonly record struct` ID wrapper, a `Money` record). Watch for raw `string` entity IDs and un-typed API arguments.
- **Repeated Switches** — the same `switch`/pattern-match on the same type recurs across the change. → replace with polymorphism, or one exhaustive switch expression both sites share.
- **Shotgun Surgery** — one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change** — one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows. The canonical .NET form: an `IFooService` interface with exactly one implementation and no test double using it — flag it unless the repo's standards endorse interface-first DI everywhere.
- **Message Chains** — long `a.B().C().D()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object. (Fluent builder APIs and LINQ chains are exempt — those are interfaces designed for chaining.)
- **Middle Man** — a class that mostly just delegates onward. → cut it, call the real target direct. The canonical .NET forms: a repository that wraps the data-access driver one-to-one adding nothing, or a command handler that only forwards to a service.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits, or throws `NotImplementedException` on interface members. → drop the inheritance, use composition, or split the interface.

### 6. Run the axis sub-agents in parallel

Start all applicable axes together when the host supports parallel delegation. Route each axis to the agent that knows the domain:

| Axis | Agent | Fallback | Also spawn when |
|---|---|---|---|
| Risk | `code-reviewer` | inline | always |
| Security | `security-reviewer` | inline | blast radius is Critical **and** the diff touches auth, crypto, secrets, CORS, or user-supplied input reaching a query |
| Standards | `code-reviewer` (second call, Standards brief) | inline | always |
| Spec | inline | — | a spec was found in step 4 |

Cursor and Claude Code can route these roles to the named profiles shipped in
`.claude/agents/`. On Codex, spawn general subagents with the complete briefs
below rather than assuming those Claude profiles load. If the host exposes no
subagent mechanism, run each brief inline in sequence and say so in the final
summary, so the reader knows the axes were not independent.

Every prompt gets: the diff command, the commit list, the blast-radius table from step 2, and the relevant step-3 pre-pass results.

**Risk sub-agent** — brief: "Review the diff for defects, highest blast radius first. Cover, in priority order: (1) **data access** — N+1 / missing `Include` or projection, raw SQL with user input, missing `CancellationToken`; (2) **security** — endpoints without explicit `[Authorize]`/`[AllowAnonymous]`, unvalidated input, secrets in code, PII in logs; (3) **concurrency** — `.Result`/`.Wait()`, `async void`, token not propagated end-to-end, unsafe shared state; (4) **integration** — missing retry/timeout on external calls, non-idempotent consumers, swallowed exceptions; (5) **correctness** — business-logic errors, null/empty/boundary cases, entities leaking past the DTO boundary; (6) **test coverage** — changed behaviour with no corresponding test change. For each finding give `file:line`, a one-sentence defect statement, and a concrete failure scenario (inputs/state → wrong output or crash). Assign each a severity per the scale supplied. Report the top 15 findings ranked by severity; say so if you had to cut any."

**Standards sub-agent** — brief: "Report — per file/hunk where relevant — (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls — documented-standard breaches can be hard, baseline smells are always judgement calls capped at Medium, and a documented repo standard overrides the baseline. Skip anything `dotnet format` or Roslyn analyzers enforce. For each finding give `file:line` and the concrete maintenance cost it imposes. Report the top 15 ranked by severity." Include the standards-source list from step 5 **plus the smell baseline pasted in full** — the sub-agent has no other access to it.

**Spec sub-agent** — brief: "Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding, and give `file:line` where the diff does or should address it. Assign severity per the scale supplied. Report all findings — spec gaps are rarely numerous."

If no spec was found, skip the Spec sub-agent and note it in the report.

### 7. Verify before reporting

False positives are the main failure mode. Before reporting, check each finding yourself:

- **Read the actual code** at the cited `file:line` — sub-agents work from a diff and miss surrounding context that can invalidate a finding (a null check three lines up, an `[Authorize]` on the parent group, an existing test elsewhere).
- **Drop** anything contradicted by the code, already enforced by tooling, or pre-existing rather than introduced by this change.
- **Mark** each survivor `CONFIRMED` (you verified the failing path) or `PLAUSIBLE` (reasoned but not proven).

Cheap and worth it — a review that cries wolf gets ignored.

### 8. Report

Publish every verified finding ranked most-severe first. Prefer the host's native structured-review or inline-comment mechanism when one is available. Each finding must include: `file`, `line`, severity-appropriate ordering, `category` (`risk` / `security` / `standards` / `spec`), `summary` (one sentence), `failure_scenario` (concrete inputs/state → consequence), `short_summary` (≤60 chars), and `verdict`.

If the host has no structured review mechanism, emit the findings under a `## Findings` Markdown heading using the same fields. Say `No findings.` when nothing survives verification. Never suppress the findings merely because a host-specific reporting tool is unavailable.

Then add a short text summary only — not a restatement of the findings:

```
Reviewed <n> files (<n> Critical, <n> High blast radius) since <fixed-point>.
Risk: n findings (worst: <one line>)
Standards: n findings (worst: <one line>)
Spec: n findings (worst: <one line>)   |   no spec available
Tooling: dotnet build / format — pass | fail
```

Report the worst issue **within each axis**. Don't declare a single cross-axis winner.

## Severity

| Severity | Means |
|---|---|
| **Critical** | Exploitable security hole, data loss or corruption, guaranteed crash/deadlock on a normal path |
| **High** | Wrong behaviour on a realistic input, missing authorization, resource leak, N+1 on a hot path, a spec requirement entirely absent |
| **Medium** | Edge-case bug, missing cancellation, partially implemented requirement, structural smell with real maintenance cost |
| **Low** | Judgement-call smell, cosmetic, speculative concern |

## Why three axes

A change can pass one axis and fail another:

- Correct, well-structured code that implements the wrong thing → **Risk + Standards pass, Spec fail.**
- Code that does exactly what the spec asked but leaks a connection → **Spec + Standards pass, Risk fail.**
- Code that's correct and matches the spec but is unmaintainable → **Risk + Spec pass, Standards fail.**

Running them as separate sub-agents stops one axis's narrative from masking another's, which is why findings are never merged into a single story.

Severity ranking in step 8 is not a violation of that separation: `category` preserves the axis, the summary reports a worst-per-axis, and ranking is a triage affordance over an objective scale — a Critical security defect genuinely does outrank a Medium smell. What the separation forbids is letting one axis's *report* subsume another's.

## Related

- `/verify` — run the tooling gate (build, tests, analyzers, format, mutation) before reviewing
- `/ship-review` — the pre-PR fan-out that calls this skill
- `/diagnosing-bugs` — when a finding needs a root cause rather than a report
