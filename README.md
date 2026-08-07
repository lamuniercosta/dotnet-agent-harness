# dotnet-agent-harness

`v0.1.0`

A gated, spec-driven development pipeline for AI coding agents — running identically on
**Cursor** and **Claude Code**, on either platform's $20 plan, with no paid third-party
service.

Most agent configs are a pile of instructions asking the model to be careful. This one
enforces a quality bar with scripts that exit non-zero, and proves in CI that those
scripts actually catch defects.

---

## What it is

| Layer | Count | What it does |
|---|---|---|
| **Pipeline** | 11 stages | Ticket to PR, with three human approval gates |
| **Gates** | 6 | Numeric thresholds, each a script with a real exit code |
| **Skills** | 25 | `SKILL.md` files — process, pipeline stages, and .NET reference |
| **Agents** | 5 | Subagents that keep long tool output out of the main context |
| **Rules** | 10 + 8 | Authored always-on rules, plus vendored glob-scoped .NET guidance |
| **Hooks** | 4 | Destructive-command guard, secret scan, format-on-edit, gate reminder |

**Only 5 files differ between the two platforms** — the adapters. Everything else is one
shared copy, because Cursor reads `.claude/skills/` and `.claude/agents/` natively.

## The gates

The point of the harness. Each is a script, not a suggestion.

| Gate | Default (all in `harness.yml`) | Tooling |
|---|---|---|
| Roslyn analyzers | CA/IDE/VSTHRD at warning+, **incl. the security families** | `Microsoft.CodeAnalysis.NetAnalyzers` |
| Cyclomatic complexity | 15 implementing, **6** after refactor | CA1502 + `CodeMetricsConfig.txt` |
| Inspections & duplication | zero findings on changed files | JetBrains InspectCode (free CLI tool) |
| Mutation score | **80%** on changed code | Stryker.NET |
| Property tests | required for pure/domain logic | FsCheck |
| Vulnerable packages | zero, including transitive | `dotnet list package --vulnerable` |

All six run locally after `dotnet tool restore`. **No account, no subscription, no hosted
service.**

Three details that carry more weight than they look:

- **`AnalysisMode=All` is load-bearing.** Under the default mode the security rule
  families (CA2100 SQL injection, CA3xxx XSS/XXE, CA5xxx crypto) are *off*. Enabling them
  is what replaces the local half of a hosted static-analysis service.
- **A gate whose analyzer is not wired fails rather than passing.** The scripts check
  their own preconditions and exit 1 with remediation.
- **Exit `0` = pass, `1` = fail, `2` = SKIPPED.** A gate with nothing to verify — **no
  `.cs` file changed against the base branch**, no property tests, no `.feature` files, or
  InspectCode switched off in config — returns 2, and nothing folds a 2 into a green verdict.
  "Skipped" and "clean" are different results, and collapsing them is exactly how a
  quality bar quietly stops existing. On the three analyzer gates, re-run with `-All`
  when you want verification rather than a diff check. The other gates take their own
  scope parameters instead of `-All` — gherkin-mutation's `-SpecsPath`, for instance,
  aims it at acceptance tests outside `specs/`, turning a skip into a run.

Every threshold lives in exactly one place: `harness.yml`. The tool configs
(`CodeMetricsConfig.txt`, `stryker-config.json`, `.editorconfig` severities) and the
constitution's Verification Gates article are all **rendered from it** by the installer.

## Install

Into an **existing** repository:

```bash
pwsh ./install.ps1 /path/to/your/repo
```

Nothing is clobbered. Files the harness owns are refreshed; files the repo owns
(`Directory.Build.props`, `.editorconfig`, `CLAUDE.md`, `harness.yml`) are created if
absent and otherwise left alone and reported. Add `-WhatIf` to see the plan without
writing anything.

Into a **new** project:

```bash
./new-project.sh MyApi ~/dev --api=rest --db=postgres --tfm=net10.0
```

which scaffolds a solution and then calls the same installer — one code path.

### Requirements

- **PowerShell 7** (`pwsh`) — the gate scripts
- **.NET SDK**, plus `dotnet tool restore` (provisions `jb` and `dotnet-stryker`)
- **`gh` CLI** — issue intake. Optional: pass a description instead
- [**Spec Kit**](https://github.com/github/spec-kit) `0.8.14` — a pinned runtime
  dependency, not vendored

### What lands in your repo

One copy of everything — no generated duplicates to drift apart:

```
.claude/skills/         25 skills   ← both platforms read this path
.claude/agents/          5 agents   ← both platforms read this path
.cursor/rules/          10 rules    ← Cursor globs them; CLAUDE.md @imports them
.cursor/rules/vendor/    8 rules    ← glob-scoped, `globs:`  (Cursor)
.claude/rules/vendor/    8 rules    ← glob-scoped, `paths:`  (Claude Code)
scripts/                gate scripts + hooks/
harness.yml             your thresholds + the harness version
CONTEXT.md              your ubiquitous language, seeded once
CLAUDE.md · .cursor/hooks.json · .claude/settings.json · .mcp.json
```

A Claude-only install still writes `.cursor/rules/`, and vice versa. Cosmetically odd,
structurally correct: one file, one home.

`vendor/` is the single exception, written to both trees — **both platforms load those
rules natively by glob**, but from different directories with different frontmatter keys,
and Cursor does not read `.claude/rules/`. Each file carries both keys; the `paths:` half
is generated from `globs:`, because the two have different semantics (`*.cs` means "any
`.cs`" to Cursor and "root only" to Claude).

## The pipeline

```
0  task             read the issue, branch off the default branch
1  grill-with-docs  MANDATORY alignment — settle vocabulary before any spec
2  spec             specify → clarify → checklist → plan → tasks → analyze
3  ── human gate 1 ──
4  gherkin          optional, opt-in
5  ── human gate 2 ── (only if stage 4 ran)
6  implement        unit + integration tests must pass
7  refactor         complexity down to the refactor threshold, property tests
8  architect        mutation above threshold, full suite
9  ── human gate 3 ──
10 ship             review fan-out, rebase, PR
```

Stage 1 is never skipped. An assumption backed by a documentation URL is settled; one
backed by recall is not.

## Agents

Five agents in `.claude/agents/`, read natively by **both** platforms — no plugin, no
adapter, nothing metered.

| Agent | Mode | Job |
|---|---|---|
| `gate-runner` | read-only | Runs the gates; returns `file:line` + cause, not raw output |
| `test-writer` | **writable** | The only agent that writes; stays inside `tests/` |
| `mutation-analyst` | read-only | Triages Stryker survivors: real gap vs equivalent mutant |
| `code-reviewer` | read-only | One named axis per call — Risk, Standards, or Spec |
| `security-reviewer` | read-only | Supply chain, authz, injection, data exposure |

## Cost

Shipped defaults put every agent on `auto` / `inherit`, so the pipeline runs inside
Cursor Pro's unlimited Auto mode and Claude Pro's limits without drawing on metered
frontier-model usage. Agents declare a *tier*, never a model id, so pinning is one block
in `harness.yml` and a model rename is a one-line fix:

```yaml
agents:
  tiers:
    deep:
      claude: inherit    # change to pin, e.g. claude-opus-5
      cursor: auto
```

## Configuration

`harness.yml` is the whole config surface. Anything omitted is auto-discovered — the
solution by glob, the base branch from git.

```yaml
pack: dotnet
baseBranch: main
tracker: github
gates:
  complexity:
    implement: 15
    refactor: 6
  mutation:
    threshold: 80
```

It is parsed by a strict subset reader: 2-space indent, `key: value`, nested maps,
`#` comments. **No flow mappings** (`{ a: 1 }`), lists, or anchors — and **unknown keys
are a hard error**, not a silent no-op. A typo that quietly reverted a threshold to its
default would be the exact failure the gates exist to prevent.

## Layout

```
skills/              25 SKILL.md — shared verbatim by both platforms
.claude/agents/       5 agents — read natively by Cursor and Claude Code alike
rules/pipeline/      10 authored always-on rules
rules/vendor/         8 third-party .NET rules, isolated and attributed (see NOTICE)
hooks/                4 hook scripts + 2 self-tests
adapters/             the only per-platform files: hook wiring, MCP, CLAUDE.md
packs/dotnet/         gate scripts + the templates they install
speckit/              extensions.yml — the entire coupling to Spec Kit
fixtures/BadCode/     deliberate violations — the proof
install.ps1           adopt-first installer
new-project.sh        generator; scaffolds, then calls install.ps1
harness.yml.example   every key, documented
VERSION · CHANGELOG.md · CONTRIBUTING.md · SECURITY.md
```

## How it's verified

`fixtures/BadCode/` is a small solution carrying a deliberate violation for each gate: a
complexity-24 method, a `DateTime.Now` call, an unread field and an `async void`, a
SQL-injection pattern, a duplicated block, a bounds check missing its lower bound, and a
boundary no test asserts.

CI installs the harness against it and asserts every gate exits **non-zero on the broken
state and zero on the fixed state**. Both directions are required: red-only would pass a
gate that always fails, green-only would pass one that never fires. A gate returning
`2` (SKIPPED) satisfies neither — it verified nothing.

```bash
pwsh ./scripts/restore-broken.ps1 && pwsh ./scripts/Assert-Gates.ps1 -Expect Fail
pwsh ./scripts/apply-fix.ps1      && pwsh ./scripts/Assert-Gates.ps1 -Expect Pass
```

This tests that the gates **catch** things, not merely that they run.

### What a gate actually prints

Real output, not a mock-up. A changed file carrying an unread field:

```text
Roslyn analyzers: FAILED - 2 diagnostic(s):
  Orders.cs:5 [WARNING] CA1823: Unused field 'Unused' (https://learn.microsoft.com/dotnet/fundamentals/code-analysis/quality-rules/ca1823)
  Orders.cs:5 [WARNING] IDE0051: Private member 'Orders.Unused' is unused (https://learn.microsoft.com/dotnet/fundamentals/code-analysis/style-rules/ide0051)

Configure severities in .editorconfig. CA1502 is checked by run-cyclomatic-complexity.ps1.
```

`file:line`, the rule, and where to change its severity — enough to act on without
opening anything else. Exit `1`.

The same gate on a clean tree, where nothing has changed against the base branch:

```text
Roslyn analyzers: SKIPPED - no .cs files changed against master.
  Nothing was verified. Run with -All to check the whole solution.
```

Exit `2`, **not** `0`. That run inspected nothing, and a harness that reported it as a
pass would be lying at the one moment it matters — the first run in a repo that has just
adopted it. Both blocks are verbatim from real runs; only the trailing absolute project
path is elided.

Eight self-tests guard the pieces that could fail silently. Each prints its own
check count — quoted here they only go stale, which has already happened twice:

```bash
pwsh ./hooks/Test-Guard.ps1                            # the guard hook
pwsh ./hooks/Test-SecretScan.ps1                       # secret scanning, both directions
pwsh ./packs/dotnet/scripts/Test-HarnessConfig.ps1     # harness.yml parsing
pwsh ./packs/dotnet/scripts/Test-ThresholdDocs.ps1     # docs vs harness.yml
pwsh ./packs/dotnet/scripts/Test-SpecKitExtension.ps1  # the Spec Kit coupling
pwsh ./packs/dotnet/scripts/Test-InstallArtifacts.ps1  # CLAUDE.md imports, constitution
pwsh ./packs/dotnet/scripts/Test-GherkinMutation.ps1   # feature-file reassembly
pwsh ./packs/dotnet/scripts/Test-GateExitContract.ps1  # 0 / 1 / 2, both directions
```

The guard's suite includes the escaped-quote payload that defeats a `grep`-based hook —
a guard that is trusted but bypassable is worse than no guard.

### One honest limitation

**The vulnerable-package gate is proven against a canned advisory document**, not a real
CVE. Committing a knowingly-vulnerable package to a public repo would mean permanent
Dependabot alerts on a repo meant to demonstrate good practice. The stub exercises the
parsing, severity classification, and exit code — not the `dotnet` CLI invocation itself.
See [`fixtures/BadCode/README.md`](fixtures/BadCode/README.md).

## What is deliberately absent

- **Secret scanning is local + CI, no vendor.** `secret-scan.ps1` warns before content
  reaches the model; gitleaks catches anything that reaches history. Replaces three
  hooks lost when SonarQube was dropped.
- **No hosted code-review service.** No Bugbot, no PR bot. The pre-PR review is
  `/ship-review`, running this harness's own agents locally.
- **No issue-tracker integration** beyond the `gh` CLI.
- **No MCP server of its own.** The two configured (`microsoft-learn`, `context7`) are
  documentation lookups; both work without a paid key.
- **CodeQL is a template, not this repo's CI** — see
  `packs/dotnet/templates/workflows/codeql.yml`. It is the optional post-PR half of the
  security story; the local gates are the blocking half.

Every one of these is a deliberate choice to keep the harness free to run and identical
on both platforms.

## Licence

MIT. Bundled third-party content — vendored rules from
[Aaronontheweb/dotnet-cursor-rules](https://github.com/Aaronontheweb/dotnet-cursor-rules),
skills adapted from
[codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit)
and [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) — is credited
in [NOTICE](NOTICE).
