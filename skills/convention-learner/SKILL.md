---
name: convention-learner
description: Detects and enforces this project's coding conventions by analyzing existing code before generating new code. Learns naming, folder structure, test organization, and style from the codebase. Use for "conventions", "coding standards", "project patterns", "enforce style", "detect patterns", "learn conventions", "code consistency".
---

# Convention Learner

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT). The upstream Roslyn MCP calls are replaced with Grep/Glob/Read plus this harness's gate scripts.

## Core Principles

1. **Observe before enforcing.** Never impose a convention without first reading the existing code. Detect first, then match.
2. **Repo config always wins.** `.editorconfig`, `Directory.Build.props`, `CodeMetricsConfig.txt`, `global.json`, `harness.yml`, and the repo's rules override any generic default.
3. **Use objective signals.** Grep/Glob for structure and naming; run the gate scripts for quality signals. Tools give data; file reads confirm intent.
4. **Document findings where they live.** Recurring conventions belong in a rules file — `.cursor/rules/*.mdc` on Cursor, an `@import` from `CLAUDE.md` on Claude Code. Domain terms belong in `CONTEXT.md` via `/domain-modeling`. Undocumented conventions are lost.
5. **Consistency over theoretical purity.** Match the dominant existing pattern even if another is arguably better.

## Detection flow

**Step 1 — Structure.** `Glob` `src/**` and `tests/**`, then name the organising principle out loud before reading any code. The three you will actually meet:

- **Layered** — top-level projects like `Api` / `Business` / `Data` / `Common` / `Setup`, features as subfolders inside each (`Business/Commands/{Feature}`). Dependencies point one way.
- **Vertical slice** — top-level `Features/{Feature}/` holding endpoint, handler, validator, and tests together. Layers barely exist.
- **Modular monolith** — top-level `Modules/{Module}/` each containing its own mini-layering, with enforced boundaries between modules.

Record which one it is, and where a *new* file of each kind belongs under it. Getting this wrong is the single most visible convention failure — a correctly-written handler in the wrong directory reads as foreign immediately.

**Step 2 — Type & naming patterns.** `Read` 3–5 representative files across layers. Detect: access modifiers (`public`/`internal`, `sealed`), interface-in-same-file (`IQueueClient`/`QueueClient`), suffixes (`Command`, `Query`, `Handler`, `Validator`, `Client`, `Setup`), record vs class for DTOs/commands, primary-constructor usage, `ArgumentNullException.ThrowIfNull` guard style, `CancellationToken ct = default` signatures.

**Step 3 — Config enforcers.** `Read` `.editorconfig` (naming, style, analyzer severities), `Directory.Build.props` (`AnalysisLevel`, `TreatWarningsAsErrors`, nullable, implicit usings), `CodeMetricsConfig.txt` (CA1502 threshold), `global.json` (SDK pin), and every file in the repo's rules directory.

**Step 4 — Quality signals.** Run from repo root and read the output as evidence of enforced rules:

```powershell
./scripts/run-roslyn-analyzers.ps1 
./scripts/run-jetbrains-inspectcode.ps1 
./scripts/run-cyclomatic-complexity.ps1 
```

**Step 5 — Summary.** Compile findings into a structured summary (naming / structure / style / testing), citing the files that confirm each pattern. Only record patterns confirmed across multiple files.

## Enforcement

**When generating code:** match every detected pattern — access modifiers, suffixes, interface placement, guard clauses, `CancellationToken` threading, telemetry through the repo's existing constants (see `/opentelemetry`), naming by functionality (not vendor).

**When reviewing code:** flag deviations with the evidence, e.g.:

```
Convention deviation: FooClient declares its interface in a separate file, but
the repo convention is interface + sealed impl in one file (IQueueClient/QueueClient
at src/Business/Clients/QueueClient.cs:1, and two siblings). See the
coding-conventions rule.
```

Cite the files that establish the convention, not just the rule — a rule the code
does not actually follow is a stale rule, and that is worth reporting too.

**Persisting a convention:** when a pattern recurs, propose adding it to the repo's rules (a new `.cursor/rules/<name>.mdc` on Cursor, or a `CLAUDE.md` `@import` on Claude Code) rather than leaving it tacit. For domain vocabulary, hand off to `/domain-modeling` to update `CONTEXT.md`.

## Anti-patterns

- **Enforcing without detecting** — imposing a generic default (e.g. "all handlers `internal`") when the repo does otherwise. Read first.
- **Overriding explicit repo config** — generating expression-bodied members when `.editorconfig` disables them. Repo config wins.
- **Documenting from one file** — record a convention only after confirming it across several files.
- **Duplicating tooling** — don't hand-flag whitespace/naming the analyzers already enforce; run the scripts and report those separately.

## Decision guide

| Scenario | Action |
|---|---|
| Joining / new to an area | Run the full detection flow |
| Generating new code | Apply detected conventions; match the nearest sibling file |
| Reviewing code | Flag deviations with file evidence; defer analyzer-covered issues to the gate scripts |
| Convention conflict (generic vs repo) | **Repo wins** |
| Recurring pattern worth locking in | Propose a repo rule; domain terms → `/domain-modeling` |
| `.editorconfig` / rule exists | Trust it, don't override |
