# dotnet-agent-harness

`v0.3.0`

A gated, spec-driven development pipeline for AI coding agents — for **Cursor**,
**Claude Code**, and **Codex**, with no paid third-party service.

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
| **Agents** | 7 | Tiered subagents for noisy stages and cheap mechanical errands |
| **Rules** | 11 + 8 | Authored always-on rules, plus vendored glob-scoped .NET guidance |
| **Hooks** | 4 | Destructive-command guard, secret scan, format-on-edit, gate reminder |

The adapters contain the host-specific wiring. The `skills/` and
`.claude/agents/` source trees are canonical; installation generates each host's
native discovery copies from them.

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

Generated agent copies carry a per-file ownership marker. Reinstallation refreshes
marked profiles and preserves unrelated agents; an unmarked same-name file is reported
as a collision and left untouched.

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

The canonical source plus host-specific delivery files:

```
.claude/skills/         25 skill copies ← Cursor and Claude Code
.agents/skills/         generated Codex copies ← invoke as `$name`
.claude/agents/          7 generated profiles ← Claude Code
.cursor/agents/          7 generated profiles ← Cursor
.codex/agents/           7 generated TOML profiles ← Codex
.cursor/rules/          11 rules    ← Cursor globs them; CLAUDE.md @imports them
.cursor/rules/vendor/    8 rules    ← glob-scoped, `globs:`  (Cursor)
.claude/rules/vendor/    8 rules    ← glob-scoped, `paths:`  (Claude Code)
scripts/                gate scripts + hooks/
harness.yml             your thresholds + the harness version
CONTEXT.md              your ubiquitous language, seeded once
CLAUDE.md · .cursor/hooks.json · .claude/settings.json · .mcp.json
AGENTS.md · .codex/config.toml · .codex/hooks.json
```

A Claude-only install still writes `.cursor/rules/`, and vice versa. Cosmetically odd,
structurally correct: the authored rule still has one home.

Vendored rules are written to both host trees — **both platforms load those rules
natively by glob**, but from different directories with different frontmatter keys,
and Cursor does not read `.claude/rules/`. Each file carries both keys; the `paths:` half
is generated from `globs:`, because the two have different semantics (`*.cs` means "any
`.cs`" to Cursor and "root only" to Claude).

## The pipeline

```
0  task             read the issue, branch off the default branch in a worktree
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

## Skills and agents

Cursor and Claude Code use the `.claude/skills/` delivery. Codex receives generated
copies in `.agents/skills/`: invoke one as `$name`, or let Codex activate it
implicitly. Named agents are generated separately for each host under
`.claude/agents/`, `.cursor/agents/`, and `.codex/agents/`.

| Agent | Mode | Job |
|---|---|---|
| `gate-runner` | read-only | Runs the gates; returns `file:line` + cause, not raw output |
| `code-scout` | read-only | Bulk search returning a compact factual conclusion |
| `edit-applier` | **writable** | One specified mechanical edit over exclusive files |
| `test-writer` | **writable** | Writes or extends tests; stays inside `tests/` |
| `mutation-analyst` | read-only | Triages Stryker survivors: real gap vs equivalent mutant |
| `code-reviewer` | read-only | One named axis per call — Risk, Standards, or Spec |
| `security-reviewer` | read-only | Supply chain, authz, injection, data exposure |

## Cost

Profiles declare a `fast`, `balanced`, or `deep` tier rather than a model id.
Installation renders the tier into native model and effort fields for every host.
Only mechanically checkable `fast` work is pinned by default:

- Claude Code: `claude-haiku-4-5-20251001`, effort `low`
- Cursor: `gpt-5.6-luna`, effort `low`
- Codex: `gpt-5.6-terra`, effort `low`

`balanced` and `deep` inherit the active host or session model. Change one tier
block to alter every profile assigned to it:

```yaml
agents:
  tiers:
    deep:
      claude:
        model: inherit
        effort: inherit
      cursor:
        model: inherit
        effort: inherit
      codex:
        model: inherit
        effort: inherit
```

The always-on delegation rule uses cheap agents only for short, one-shot errands
whose answer is much smaller than their input. It deliberately has no numeric
threshold: the runtime behavior is guidance and cannot be proven by CI.

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
skills/              25 SKILL.md sources → host discovery directories on install
.claude/agents/       7 canonical profiles → three host discovery formats
rules/pipeline/      11 authored always-on rules
rules/vendor/         8 third-party .NET rules, isolated and attributed (see NOTICE)
hooks/                4 hook scripts + 3 self-tests
adapters/             the only per-platform files: hook wiring, MCP, agent instructions
packs/dotnet/         gate scripts + the templates they install
speckit/              extensions.yml — the entire coupling to Spec Kit
fixtures/BadCode/     deliberate violations — the proof
install.ps1           adopt-first installer
new-project.sh        generator; scaffolds, then calls install.ps1
harness.yml.example   every key, documented
VERSION · CHANGELOG.md · CONTRIBUTING.md · SECURITY.md
```

Spec Kit `0.8.14` integrates with Codex through
`specify init --integration codex`; it supplies the `$speckit-*` skills alongside the
harness skills.

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

Repository self-tests guard the pieces that could fail silently. Each prints its own
check count — quoted here they only go stale, which has already happened twice:

```bash
pwsh ./hooks/Test-Guard.ps1                            # the guard hook
pwsh ./hooks/Test-SecretScan.ps1                       # secret scanning, both directions
pwsh ./hooks/Test-GateNudge.ps1                        # Codex advisory output contract
pwsh ./scripts/local/Test-JsonProperty.ps1             # repo-local issue helper JSON
pwsh ./scripts/local/Test-SelfSkills.ps1               # self-development skill delivery
pwsh ./packs/dotnet/scripts/Test-HarnessConfig.ps1     # harness.yml parsing
pwsh ./packs/dotnet/scripts/Test-ThresholdDocs.ps1     # docs vs harness.yml
pwsh ./packs/dotnet/scripts/Test-SpecKitExtension.ps1  # the Spec Kit coupling
pwsh ./packs/dotnet/scripts/Test-InstallArtifacts.ps1  # host agents, imports, constitution
pwsh ./packs/dotnet/scripts/Test-GherkinMutation.ps1   # feature-file reassembly
pwsh ./packs/dotnet/scripts/Test-TaskBranchScripts.ps1 # task branch and worktree safety
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

- **Secret scanning is local + CI, no vendor.** `secret-scan.ps1` warns before a
  submitted prompt reaches the model; hosts with a file-read event scan that path too.
  Codex exposes no file-read event, a gap its installed `AGENTS.md` calls out. Gitleaks
  catches anything that reaches history. This replaces the hooks lost with SonarQube.
- **No hosted code-review service.** No Bugbot, no PR bot. The pre-PR review is
  `/ship-review`, running this harness's own agents locally.
- **No issue-tracker integration** beyond the `gh` CLI.
- **No MCP server of its own.** The two configured (`microsoft-learn`, `context7`) are
  documentation lookups; both work without a paid key.
- **CodeQL is a template, not this repo's CI** — see
  `packs/dotnet/templates/workflows/codeql.yml`. It is the optional post-PR half of the
  security story; the local gates are the blocking half.

Every one of these is a deliberate choice to keep the harness free to run without a
hosted service dependency.

## Licence

MIT. Bundled third-party content — vendored rules from
[Aaronontheweb/dotnet-cursor-rules](https://github.com/Aaronontheweb/dotnet-cursor-rules),
skills adapted from
[codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit)
and [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) — is credited
in [NOTICE](NOTICE).
