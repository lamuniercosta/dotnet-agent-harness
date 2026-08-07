# Development instructions

This repository uses **dotnet-agent-harness**. The pipeline, gates, and conventions
below are enforced by scripts, not by good intentions.

Codex reads this file natively from the repository root. Unlike the Cursor and
Claude Code adapters, it **imports nothing** — Codex has no `@import`, so the
always-on rules are distilled here in full rather than referenced. The same rules
live in `.cursor/rules/*.mdc`; if the two ever disagree, those files are the
source and this one is stale — say so rather than picking one silently.

Read [Limitations under Codex](#limitations-under-codex) before your first
session. Project hooks must be reviewed before their safety nets run.

## Non-negotiables

- `TimeProvider` for time, injected seeded `Random` for randomness. `DateTime.Now`
  is in `BannedSymbols.txt` and **fails the build** (RS0030 is an error).
- A surviving mutant is a missing test. Fix the test, never the threshold.
- Match the repo's existing architecture, assertion library, and mocking library.
  Introducing a second one is a defect.
- No explanatory comments. In tests, `// arrange` / `// act` / `// assert` are the
  one exception.
- Never mock the data-access driver for behaviour that depends on real query
  translation or serialisation — use Testcontainers.
- Never hardcode a threshold, and never edit a generated file — the next install
  overwrites it.
- Never lower a gate threshold to make a gate pass. That is the one move the
  pipeline exists to prevent.

## Coding conventions

- Define an interface in the same file as its primary implementation
  (`IQueueClient`/`QueueClient`). Separate files only where the architecture
  already demands it, e.g. `Business/Abstractions/`.
- Name types and members by **functionality, not vendor**: `MessageTracePropagator`,
  not `ServiceBusTracePropagator`. Vendor names are for SDK types and
  vendor-mandated config keys only.
- Follow the pattern in neighbouring code over any example in this file.

## Documentation sources

When a question turns on a specific API's surface or semantics, query the MCP
documentation servers rather than answering from memory or a web search:

- **microsoft-learn** — .NET/C#, ASP.NET Core, Azure (Functions, Service Bus, Blob
  Storage, Entra, Key Vault, App Insights), MSBuild, Roslyn `CA*`/`IDE*` rules.
  Microsoft Learn always wins on a Microsoft or Azure topic.
- **context7** — everything else: MongoDB C# driver, Polly, xUnit, FsCheck,
  Reqnroll, NSubstitute, Testcontainers, WireMock.NET, Stryker.NET, k6.

Cite the source when a doc answer drives a decision. Skip the lookup when
refactoring working code or discussing design in the abstract.

These servers are registered in `.codex/config.toml`. See
[Limitations under Codex](#limitations-under-codex) — they load only once you
have trusted the project.

## Verification commands

```powershell
./scripts/run-roslyn-analyzers.ps1          # CA/IDE/VSTHRD + the security families
./scripts/run-cyclomatic-complexity.ps1     # tightened at the refactor gate
./scripts/run-jetbrains-inspectcode.ps1     # a different engine; catches duplication
./scripts/run-property-tests.ps1
./scripts/run-vulnerable-packages.ps1
dotnet test
dotnet stryker                              # minutes-expensive; pre-PR only
```

The three analyzer gates — `run-roslyn-analyzers.ps1`,
`run-cyclomatic-complexity.ps1`, `run-jetbrains-inspectcode.ps1` — take
`-BaseRef`, `-Files "a.cs","b.cs"`, and `-All`; with no args they analyse the
files changed against the base branch. The rest take their own parameters
(`run-vulnerable-packages.ps1`: `-Severity`, `-IncludeTransitive`;
`run-property-tests.ps1`: `-Project`, `-Category`) and **error out on `-All`**.
Every script accepts `-Help`; ask it rather than assuming a flag.

**Exit 0 = pass, 1 = fail, 2 = SKIPPED.**
A SKIPPED gate verified nothing and is never folded into a green verdict.

**A gate that could not run has not passed.** The scripts enforce this themselves:
if the analyzer they depend on is not wired, they exit 1 with remediation rather
than reporting a pass they did not earn. Report an unrunnable gate as SKIP, never
fold it into a green verdict, and never substitute plain `dotnet build`.

### Running the gates under `codex exec`

The gate scripts are plain PowerShell with no editor coupling, so they run
unchanged non-interactively. This invocation is verified:

```powershell
codex exec --sandbox danger-full-access -C <repo> "Run exactly: pwsh -NoProfile -File ./scripts/run-roslyn-analyzers.ps1 ; then report ONLY the numeric exit code. Change nothing."
```

Ask for the **numeric exit code** explicitly. Left to its own phrasing the agent
narrates a verdict, and on one observed run it reported a Windows error number as
though it were the script's exit code. The contract above is 0/1/2 — trust that,
not the prose.

#### Windows: the sandbox cannot spawn a Store-installed pwsh

`--sandbox read-only` and `workspace-write` use a Windows restricted-token
sandbox that **cannot launch `pwsh.exe` when PowerShell 7 came from the Microsoft
Store**, which is where `winget install Microsoft.PowerShell` puts it by default.
It fails before the script runs, with `CreateProcessAsUserW failed: 5` (access
denied) or `: 2` (not found) — never a gate result.

The sandbox itself is fine; it is the WindowsApps package that cannot be spawned.
Verified with `codex sandbox` (which runs a command with no agent turn):

```powershell
codex sandbox git --version                              # works
codex sandbox powershell -NoProfile -Command "exit 3"    # works, exit code 3 propagates
codex sandbox pwsh -NoProfile -Command "exit 3"          # CreateProcessAsUserW failed
```

Two ways out, best first:

1. **Install PowerShell 7 from the MSI** rather than the Store, so `pwsh.exe`
   lands in `C:\Program Files\PowerShell\7` as an ordinary executable. Ordinary
   executables spawn fine under the sandbox, as `git` and `powershell` above show.
   This is the inference the evidence supports; it has not been tested here.
2. **`--sandbox danger-full-access`**, which is what the verified invocation uses.
   It runs the command with **no sandbox at all** — acceptable for a read-only
   gate run in a repo you trust, and not something to leave as your default.

Do not fall back to Windows PowerShell 5 (`powershell.exe`) to dodge this. It
spawns, but the gate scripts target PowerShell 7 and a green result from the
wrong interpreter is worse than a failure to launch.

Anything that must write (`dotnet test`, `dotnet stryker`) needs at least
`workspace-write`.

## Gates, in order

**After editing any `.cs` file**, and before calling implementation work done, all
three of these must pass:

| Script | Catches |
|---|---|
| `./scripts/run-roslyn-analyzers.ps1` | CA/IDE/VSTHRD/RS. Severities in `.editorconfig`; banned APIs in `BannedSymbols.txt` |
| `./scripts/run-cyclomatic-complexity.ps1` | `CA1502`, ceiling from `gates.complexity.implement` in `harness.yml` (default 15) |
| `./scripts/run-jetbrains-inspectcode.ps1` | WARNING+ inspections `dotnet build` and Roslyn miss, notably duplication |

**Refactor gate** — the complexity bar tightens to `gates.complexity.refactor` in
`harness.yml` (default 6). Fix `CA1502` by extracting helpers and using early
returns; `#pragma warning disable CA1502` is for generated or genuinely
irreducible code, with a justification, never to clear the gate. FsCheck property
tests are required for pure/domain logic in changed code, tagged
`[Trait("Category", "Property")]`.

**Architect gate** — `dotnet tool restore`, then
`dotnet stryker --config-file stryker-config.json`, plus the full suite. The score
floor is `gates.mutation.threshold` in `harness.yml` (default 80), as a percentage
on changed code. Run `./scripts/run-gherkin-mutation.ps1` only when
`specs/<feature>/acceptance/*.feature` exists; it must leave zero survivors.

## Workflow

The harness pipeline runs in fixed order. In Codex, use the matching harness skill when
available (`$name`, or implicit activation from a matching request); otherwise carry out
the phase directly — see [Limitations](#limitations-under-codex).

1. **Task intake** — read the issue, create the branch
2. **Grill** — settle vocabulary and assumptions in `CONTEXT.md` + ADRs before any
   spec. Non-negotiable; a spec written before the grill encodes the wrong nouns
3. **Spec → plan → tasks** — *human gate 1*
4. **Implement** — TDD; tests must pass
5. **Refactor** — the refactor gate above
6. **Architect** — the architect gate above — *human gate 3*
7. **Ship review** → rebase → PR

Never skip the grill, and never route a failing gate to lowering its threshold.

## GitHub workflow

- Read issues through `gh` only: `gh issue view 142 --json number,title,body,labels`
- Branch with `./scripts/new-task-branch.ps1 -Issue 142` (`-Type bug`, or
  `-Description "..." -Type feature`). Pattern: `{feature|bug|hotfix}/{issue}-{slug}`.
  `hotfix` is never inferred — it is always asked for explicitly.
- That creates a **git worktree** at `<repo>.worktrees/{type}-{issue}-{slug}`, beside
  the repo, and everything after intake happens in it: `cd` there and run
  `dotnet tool restore`. One checkout serialises tasks, so a dirty main checkout does
  not block intake. `-NoWorktree` switches this checkout instead and still refuses a
  dirty tree. Never put a worktree inside the repo — git hides linked worktrees from
  `git status`, but `dotnet build`, InspectCode, and recursive globs still walk them.
  `harness.yml` is copied in for you (gitignored, so git will not); `.specify/` is not,
  so run `specify init` there before any `$speckit-*` step. Clean up with
  `git worktree remove <path>` after the merge.
- Commit subjects carry the issue as a **suffix, never a prefix**:
  `Add dark mode toggle (#142)`. A leading `#` is stripped as a comment by git's
  editor path, silently losing the reference.
- Rebase before a PR: `./scripts/rebase-task-branch.ps1 -Push`. Push with
  `--force-with-lease`.
- Only commit when asked. Never open or push a PR on your own initiative.

## README maintenance

Update `README.md` when a change alters something a **consumer of the service**
needs to know: API surface (endpoints, request/response shapes, status codes),
behaviour (retry, recovery, validation, error handling), configuration (settings,
environment variables, `appsettings*.json` keys), telemetry (span/metric names,
attribute values), or the data model. Mark resolved entries under Risks &
Limitations as **Resolved / Implemented / Mitigated**.

Process and workflow changes — gate scripts, analyzer severities, `.editorconfig`,
rules, MCP servers — do **not** belong in `README.md`. They belong in the rule
that owns them under `.cursor/rules/`, and in this file.

## Configuration

`harness.yml` at the repo root is the entire configuration surface — thresholds,
base branch, tracker, agent model tiers. It is the **single source of truth**:
`CodeMetricsConfig.txt`, `stryker-config.json`, and the `.editorconfig` gate
severities are all rendered from it by `install.ps1` on every run.

`.specify/memory/constitution.md` is rendered **only when absent**. Once it exists
it is the project's own law and no install touches it again — so if it quotes a
threshold, that number is yours to keep in step with `harness.yml`.

## Limitations under Codex

These are current gaps in the **harness's** Codex support, not defects in Codex.
They are listed because each one is silent, and a safety net you believe in but
do not have is worse than one you know is missing.

### Lifecycle hooks require trust, and cannot scan file reads

The harness installs `.codex/hooks.json` with four protections:

- `secret-scan.ps1` warns when a submitted prompt contains a credential shape;
- `guard.ps1` blocks the narrow set of destructive shell commands and protected
  file writes listed under [Non-negotiables](#non-negotiables);
- `format-on-edit.ps1` formats edited C# files; and
- `gate-nudge.ps1` reminds the agent that analyzer gates remain pending.

Project-local hooks run only after the project is trusted **and each exact hook
definition has been reviewed and trusted**. Open `/hooks` when Codex reports
unreviewed hooks. A changed hook is skipped until its new definition is reviewed,
so do not assume these protections are active merely because the files exist.

Codex currently exposes no file-read lifecycle event. The prompt scanner can warn
before submitted text leaves the machine, but it cannot inspect a credential that
Codex reads from a file. **Never ask Codex to read a file containing a live
credential.** If one reaches a model provider, rotate it; no later commit hook can
recall it. `gitleaks` in CI covers only the commit-time half.

Hooks are guardrails, not a complete enforcement boundary. Keep Codex's sandbox
enabled and read approval prompts rather than approving reflexively.

### Skills are available; named Claude profiles are not

The harness installs its canonical `skills/` source to `.agents/skills/`, which Codex
discovers; Cursor and Claude Code receive the same source under `.claude/skills/`.
Invoke a harness skill as `$name`, or let Codex activate it implicitly when the request
matches its description.
For Spec Kit `0.8.14`, initialize Codex with `specify init --integration codex`; that
provides the `$speckit-*` commands.

Codex does not read the named `.claude/agents/` profiles. For their work, give a generic
Codex subagent the profile's brief in the delegation prompt; when delegation is not
appropriate, perform the work inline.

### MCP servers need the project trusted

`.codex/config.toml` is project-scoped, and Codex loads project config **only for
a trusted project**. Until you open the repo with `codex` and trust it, the two
documentation servers are not registered and the agent will answer API questions
from memory instead. `codex mcp` lists what is actually registered when in doubt.
