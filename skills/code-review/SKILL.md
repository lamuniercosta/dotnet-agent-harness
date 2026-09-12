---
name: code-review
description: Review C# changes since a fixed point (commit, branch, tag, or merge-base) along three axes — Risk (bugs, security, concurrency, coverage gaps), Standards (does the code follow this repo's documented standards?), and Spec (does it match what the issue/spec asked for?). Classifies the diff first: no `.cs` files is out of scope for this skill. Scores blast radius, runs a Roslyn pre-pass, fans out to parallel sub-agents, verifies findings, and reports them severity-ranked. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

Three-axis review of the **C#** diff between `HEAD` and a fixed point the user supplies:

- **Risk** — is the code correct, safe, and adequately tested?
- **Standards** — does the code conform to this repo's documented coding standards?
- **Spec** — does the code faithfully implement the originating issue / spec?

This skill reviews compiled C# evidence only. A diff with no `.cs` files is **out of scope for this skill** — a normal outcome, not a failed review. There is no generic language fallback. This C#-only boundary is the ADR 0022 contract (docs/adr/0022-harness-targets-csharp-only.md): no compiled C# means the review is declined as out of scope, with a zero-finding declined artifact, not rerouted to a generic reviewer.

Each axis runs in an isolated sub-agent when the host supports delegation, with parallel execution when available; otherwise the briefs run inline. Findings are then verified, ranked by severity, and published through the host's native review mechanism, with a Markdown fallback.

## Process

### Classify the diff (before Step 0)

Before resolving loop terms (Step 0) and before blast-radius scoring (Step 2), classify changed file extensions.

Whatever the user said is the fixed point — a commit SHA, branch name, tag, `main`, `HEAD~5`, etc. If they didn't specify one, ask for it. If the caller supplies an explicit diff range, classify and later review only that range.

Resolve the range only far enough to list extensions: `git rev-parse` the fixed point (or the explicit range) and `git diff --name-only <fixed-point>...HEAD` (three-dot, or the caller-supplied range). If the range itself cannot be resolved — bad ref, unreadable, or empty diff — stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**. That is not an out-of-scope refusal.

If the non-empty file list contains **zero** `.cs` files:

- Stop before Step 0 loop-term fail-closed, before Step 2 blast-radius scoring, before Step 3 Roslyn/tooling, before Step 3a pre-pass artifact creation, and before Steps 4–7 fan-out.
- Report a normal **out of scope for this skill** outcome — not a failed review, not **Could not run**, not **NEEDS FIXES**. Do not route to `/remediate`.
- Name what was skipped and why: no compiled C# in the diff, so Roslyn, `dotnet format --verify-no-changes`, `dotnet build`, blast-radius scoring, and axis fan-out do not run.
- Name the applicable deterministic repo gates instead (consumer `./scripts/run-*.ps1`, or this harness's PowerShell tests and lint grep gates). There is no generic language fallback and no prose blast-radius row.
- Skip Steps 0–7. Go to Step 8 and emit the declined findings artifact: `declined: true`, non-null `decline_reason`, `findings: []`.

`.cs` presence is the proxy. A mixed diff with any `.cs` file — including incidental, generated, or fixture C# — takes the C# path below. That cost is accepted.

If any changed file has a `.cs` extension, continue at Step 0.

### 0. Resolve loop terms

Resolve `FEATURE_DIR` as `/pipeline`: task value, or `.specify/scripts/powershell/check-prerequisites.ps1 -Json`. Read `<FEATURE_DIR>/brief.md` for **closing bar**, **frozen scope**, and **round cap** before Step 1. If the feature or any term cannot be resolved unambiguously, fail closed: stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**. Do not infer defaults or choose among multiple briefs.

### 1. Pin the fixed point

Reuse the fixed point and range already resolved during classification. Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or empty diff should fail here — not inside three parallel sub-agents.

If the caller supplies an explicit diff range, review only that range.

### 2. Score blast radius

Blast radius sets review depth, not line count. A one-line middleware change outranks a 300-line rename. Score each changed file from `git diff --stat`:

| Blast radius | Examples | Depth |
|---|---|---|
| **Critical** | Middleware, auth/authz, DB migrations, shared kernel, CI/CD, crypto, public contracts | Thorough — every code path |
| **High** | Public API changes, message consumers, EF configuration, new module, cache keys | Focused — consumers + behaviour |
| **Medium** | New feature following existing patterns, bug fix, new endpoint | Standard — checklist pass |
| **Low** | Docs, formatting, renames, logging statements | Glance — build + tests pass |

Record this scoring in the pre-pass artifact (Step 3a) so each axis can spend its budget on Critical/High files. If the whole diff is Low, say so and skip the fan-out — a glance plus green tooling is the review. Do not also relay the table inline into sub-agent prompts.

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

Do not relay these results inline into sub-agent prompts. Write them into the pre-pass artifact in Step 3a.

### 3a. Write the pre-pass artifact

After Steps 1–3 complete, write one Markdown scratch file that the Step 6 axes read themselves. Report the absolute path for Step 6. There is no fallback to inline relay.

**Header** — every artifact starts with a Markdown header block containing these fields:

| Field | Source | Purpose |
|---|---|---|
| `repository` | Absolute path to the repo root | Prevents cross-repo collision |
| `branch` | Current branch name | Context for the reader |
| `head_sha` | Full 40-char `git rev-parse HEAD` | Freshness — must match consumer's HEAD |
| `fixed_point` | The base ref or SHA from Step 1 | Prevents wrong-base stale reads |
| `diff_range` | The three-dot range (`<fixed-point>...HEAD`) | Explicit scope binding |
| `written_at` | UTC ISO-8601 timestamp | Audit trail; not used for verification |

**Body**, in order:

1. **Diff command** — the literal `git diff <fixed-point>...HEAD`
2. **Commit list** — output of `git log <fixed-point>..HEAD --oneline`
3. **Blast-radius table** — the scored table from Step 2
4. **Roslyn pre-pass results** — from Step 3, when available; omit this section when the Roslyn MCP tools are unavailable
5. **Tooling-gate status** — `dotnet format --verify-no-changes` and `dotnet build` pass/fail, with diagnostics on failure
6. **Severity scale** — the table from `## Severity` below, so sub-agents can assign severity without a parent-relayed copy

Keep these **out** of the artifact (they stay inline at Step 6): smell baseline, standards-source list from Step 5, spec path from Step 4.

**Allowed roots**: `<temp>/pr-review` and `<temp>/scratch` only. Both use the platform temporary directory, not a relative path. Working-tree roots are forbidden — no gitignore fallback. The path carries a repo-unique segment (for example a hash of the repo root's absolute path) **and this skill's own segment**, e.g. `<temp>/pr-review/<repo-hash>/code-review/pre-pass-<full-40-char-sha>.md` (same shape under `<temp>/scratch/`), so two repos sharing a temp directory cannot collide and the ship-review pre-pass of the same repo can never write the same file. Filename: `pre-pass-<full-40-char-sha>.md`. Short SHAs are forbidden.

**Safe write**: if the target path is a symlink or reparse point, abort. Write to a temp file and rename onto the final path; never write the final path directly. If the target already exists with a different `fixed_point` or `head_sha`, abort rather than overwrite. On any abort: stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**.

**Write-time freshness**: immediately before writing, re-resolve `git rev-parse HEAD`. If it differs from the HEAD captured in Step 1, abort (fail closed): stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**.

**Read-only during fan-out**: `code-reviewer` and `security-reviewer` have no dedicated Edit or Write tools; Bash is available but not a sanctioned write path. Integrity during fan-out relies on that profile constraint, not filesystem permissions.

**Lifecycle**: session-scoped. No mandatory cleanup. The parent may delete the file after Step 7. The file holds branch names, commit messages, and pre-pass results for unmerged work — same information scope as the findings artifact.

### 4. Identify the spec source

Look for the originating spec, in this order:

1. **SpecKit artifacts.** If the repo uses SpecKit (`specify-cli`), the spec lives under `specs/<NNN-feature-name>/` — read `spec.md` as the primary spec, and `plan.md` / `tasks.md` for the intended decomposition. Match the feature directory to the branch name (SpecKit branches and spec directories share the `NNN-feature-name` slug).
2. Issue references in the commit messages (`#123`, `Closes #45`, etc.) — fetch via `gh issue view <n>` or the tracker the repo documents.
3. A path the user passed as an argument.
4. A PRD/spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
5. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

### 5. Identify the standards sources

Anything in the repo that documents how code should be written: `CODING_STANDARDS.md`, `CONTRIBUTING.md`, the conventions sections of `CLAUDE.md`/`AGENTS.md`, `.cursor/rules/*.mdc`, `harness.yml` (the gate thresholds), and — .NET-specific — `.editorconfig` (style + analyzer severities), `Directory.Build.props` (`AnalysisLevel`, `AnalysisMode`, `TreatWarningsAsErrors`, analyzer package references), `BannedSymbols.txt`, and any `.globalconfig`.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** in `./smell-baseline.md` (same directory as this `SKILL.md`) — a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation — cap these at **Medium** severity unless the repo documents the rule explicitly.

### 6. Run the axis sub-agents in parallel

Start all applicable axes together when the host supports parallel delegation. Route each axis to the agent that knows the domain:

| Axis | Agent | Fallback | Also spawn when |
|---|---|---|---|
| Risk | `code-reviewer` | inline | always |
| Security | `security-reviewer` | inline | blast radius is Critical **and** the diff touches auth, crypto, secrets, CORS, or user-supplied input reaching a query |
| Standards | `code-reviewer` (second call, Standards brief) | inline | always |
| Spec | inline | — | a spec was found in step 4 |

Claude Code, Cursor, and Codex can route these roles to their generated named
profiles. If the host exposes no subagent mechanism, run each brief inline in
sequence and say so in the final summary, so the reader knows the axes were not
independent.

Every prompt gets the path to the pre-pass artifact written in Step 3a. The sub-agent reads that file as its first action and verifies `repository`, `head_sha`, `fixed_point`, and `diff_range` against its own environment. If the file is missing, unreadable, or any of those fields mismatch — or the sub-agent cannot verify (no shell, wrong cwd) — it fails closed. No inline relay of the diff command, commit list, blast-radius table, Roslyn results, tooling-gate status, or severity scale. "Per the scale supplied" means the scale in the artifact just read.

Non-artifact inline content stays in the prompt, not the file: Standards also receives the Step 5 standards-source list and reads `./smell-baseline.md`; Spec also receives the spec path from Step 4.

_Each sub-agent reads its own axis brief from the directory that contains this `SKILL.md`. Resolve `./risk-brief.md`, `./standards-brief.md`, and `./spec-brief.md` relative to that directory, not the process working directory. If any companion file cannot be read, stop and report — do not proceed without it._

If no spec was found, skip the Spec sub-agent and note it in the report.

### 7. Verify before reporting

False positives are the main failure mode. Before reporting, check each finding yourself:

- **Read the actual code** at the cited `file:line` — sub-agents work from a diff and miss surrounding context that can invalidate a finding (a null check three lines up, an `[Authorize]` on the parent group, an existing test elsewhere).
- **Drop** anything contradicted by the code, already enforced by tooling, or pre-existing rather than introduced by this change.
- **Evidence threshold.** Keep a finding only when it has a concrete failure scenario, a cited documented rule, or a quoted spec line. Otherwise ask a question or drop it — unproven concerns become questions/context, not findings.
- **Minimality.** Challenge unnecessary scope and abstraction in any proposed correction before it reaches the report.
- **Cap.** Report findings meeting the evidence threshold, up to 15. The 15 is a cap, not silent truncation: say so if any evidence-backed findings were cut.
- **Mark** each survivor `CONFIRMED` (you verified the failing path) or `PLAUSIBLE` (reasoned but not proven).

Cheap and worth it — a review that cries wolf gets ignored.

### 8. Report

Publish every verified finding ranked most-severe first. Prefer the host's native structured-review or inline-comment mechanism when one is available. Each finding must include: `file`, `line`, severity-appropriate ordering, `category` (`risk` / `security` / `standards` / `spec`), `summary` (one sentence), `failure_scenario` (concrete inputs/state → consequence), `short_summary` (≤60 chars), and `verdict`.

If the host has no structured review mechanism, emit the findings under a `## Findings` Markdown heading using the same fields. Say `No findings.` when nothing survives verification. Never suppress the findings merely because a host-specific reporting tool is unavailable.

Additionally write a findings artifact as JSON via a native JSON serializer only (no concatenation or interpolation). Envelope: `schema` pr-review/findings@1; `head_sha` repository-resolved full 40-char; required `fixed_point` (base ref/SHA); `generated_at` UTC Z; `declined`; `decline_reason`; `findings` matching `skills/pr-review/scripts/review-schema.json` `$defs/finding`. Verified only. Clean: declined false, findings []. Decline only from evidenced DEV-113 no-compiled-C#: declined true, non-null decline_reason, findings []. Finding requires severity, category, file, verdict; add line, start_line, side when pinned, plus summary, failure_scenario, short_summary; rule if Standards cites one; emit `fix` only when the schema carries it, otherwise omit. Absolute caller path else host temp/scratch. Allowed roots: `<temp>/pr-review` and temp/scratch — not working tree unless gitignored. Symlink/reparse check; no unsafe overwrite; atomic temp+rename. Report the path.

Then add a short text summary only — not a restatement of the findings. On a declined no-C# classification, skip the axis/tooling block and say:

```
Reviewed <n> files since <fixed-point> — out of scope for this skill (no .cs in the diff).
Skipped: loop terms, blast-radius scoring, Roslyn, tooling, pre-pass artifact, fan-out.
Applicable gates: this repo's deterministic scripts / lint, plus human reading.
```

Otherwise:

```
Reviewed <n> files (<n> Critical, <n> High blast radius) since <fixed-point>.
Risk: n findings (worst: <one line>)
Standards: n findings (worst: <one line>)
Spec: n findings (worst: <one line>)   |   no spec available
Tooling: dotnet build / format — pass | fail
```

Report the worst issue **within each axis**. Don't declare a single cross-axis winner.

A declined no-C# outcome (`declined: true`, non-null `decline_reason`, `findings: []`) is **out of scope for this skill**, not a failed review: it does not go to `/remediate`. Sort verified findings against `brief.md`'s closing bar and frozen scope. Above the bar go to `/remediate`. Below the bar or outside the frozen scope go to Follow-ups; never silently relabelled `Non-blocking`. Keep the original source and severity. The stage clears only when no finding above the closing bar remains. A Critical or High finding deferred to Follow-ups does not cause another post-cap fix commit, but it still prevents the review stage from clearing.

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
