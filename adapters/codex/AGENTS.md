# Development instructions

This repository uses **dotnet-agent-harness**. The pipeline, gates, and conventions
below are enforced by scripts, not by good intentions.

Codex reads this file natively from the repository root. Unlike the Cursor and
Claude Code adapters, it **imports nothing** — Codex has no `@import`, so the
three always-on rules are distilled here rather than referenced. The eight
scoped rules load through skill invocation (and, on Cursor/Claude, glob/`paths`
matching). `.cursor/rules/*.mdc` is the canonical source for each; if this file
and those ever disagree, those files are the source and this one is stale —
say so rather than picking one silently.

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

## Cost-aware delegation

Agent tiers reflect the cost of a silent miss, not apparent difficulty. Use a
`fast` named agent for a cheap errand only when all four conditions hold:

1. You need a compact answer, not source material you will quote, edit, or
   reason over line by line.
2. The material to inspect is much larger than the returned answer.
3. The brief is short and complete without replaying accumulated conversation.
4. The work is one-shot and should not need clarification.

Keep the work inline when you need the contents afterward, the brief transfers
substantial context, trusting the result requires re-reading the source, or one
tool call answers the question. The governing asymmetry is: **delegate
conclusions; keep required content inline.** There is no numeric threshold.

A cheap errand may gather evidence for a verdict you will make, but may not make
semantic verdicts, feed a human gate, or perform unspecified writes. It also may
not feed a grilling session in progress — that follows from the four conditions,
not from an exception to them: a fact put to a live interrogation is material you
reason over to form the next question (1), and its brief cannot be complete
without replaying the conversation so far (3). One carve-out: a single
reconnaissance pass before the first question, where no conversation exists yet
to replay. A mid-grill lull is not a new pre-grill pass. `gate-runner`
has one mechanical exception: it may translate a reported command and exit code
into `Pass`, `Failure`, `Skipped`, or `Could not run`; it may not dismiss
findings, judge equivalent mutants, or overrule tool evidence.

Delegate a writable errand to `edit-applier` only when the brief gives one exact
transformation, an explicit file set, and an objective check. Those files belong
exclusively to the errand until it returns. Do not edit them concurrently, and
parallel writable errands must have disjoint file sets. Review the diff afterward.

If an errand is ambiguous, partial, or untrustworthy, finish it inline and do not
re-brief the cheap agent. If partial edits already exist, review the current diff
and continue from it; do not roll back automatically.

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
than reporting a pass they did not earn. Report an unrunnable gate as `Could not
run`; reserve `Skipped` for exit 2, never fold either into a green verdict, and
never substitute plain `dotnet build`.

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

## Workflow

The harness pipeline runs in fixed order. In Codex, use the matching harness skill when
available (`$name`, or implicit activation from a matching request); otherwise carry out
the phase directly — see [Limitations](#limitations-under-codex).

1. **Task intake** — read the issue, create the branch
2. **Grill** — settle vocabulary and assumptions in `CONTEXT.md` + ADRs before any
   spec. Non-negotiable; a spec written before the grill encodes the wrong nouns
3. **Spec → plan → tasks** — *human gate 1*
4. **Implement** — TDD; tests must pass
5. **Refactor** — `/refactor`
6. **Architect** — `/architect`
7. **Code review** *(gated, stage 9)* — `/code-review`; above-bar findings → `/remediate` → re-review
8. **Ship** — rebase → `/ship-review` → open the PR
9. **Address PR review** *(conditional, stage 11)* — `/address-pr-review` when external feedback arrives
10. **Merge** — *human gate 3*

Never skip the grill, and never route a failing gate to lowering its threshold.

`/code-review` and `/ship-review` have no numeric gate, unlike Implement/Refactor/Architect — they must be given a stop condition explicitly, in `brief.md`, before Stage 6 (Implement): a closing bar (which severities block), a frozen scope ("anything else is a follow-up issue, not a finding in this round."), and a round cap of two rounds (initial pass + one fix-and-re-run). The closing bar and frozen scope decide which findings get a fix commit on the open loop; below-bar or out-of-scope items become follow-up issues, never a fix commit on this loop. Past the cap, unresolved findings become follow-up issues instead of more fix commits. A Critical or High finding deferred to a follow-up still keeps the stage at **NEEDS FIXES** and prevents READY or a PR suggestion — deferral stops further fix commits, it does not make the diff READY. Amendments to the closing bar or scope after a loop starts are a new issue, not a widening of the current one.

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

### Skills and named agents are available

The harness installs its canonical `skills/` source to `.agents/skills/`, which Codex
discovers; Cursor and Claude Code receive the same source under `.claude/skills/`.
Invoke a harness skill as `$name`, or let Codex activate it implicitly when the request
matches its description.
For Spec Kit `0.8.14`, initialize Codex with `specify init --integration codex`; that
provides the `$speckit-*` commands.

The harness generates seven named profiles under `.codex/agents/`: `gate-runner`,
`code-scout`, `edit-applier`, `test-writer`, `mutation-analyst`, `code-reviewer`,
and `security-reviewer`. Their model and reasoning effort come from the profile's
tier in `harness.yml`; inherited fields fall back to Codex's configured default.
`code-scout` overlaps with Codex's built-in `explorer` without replacing it. A
consumer who prefers the built-in can remove the generated `code-scout` profile.

### MCP servers need the project trusted

`.codex/config.toml` is project-scoped, and Codex loads project config **only for
a trusted project**. Until you open the repo with `codex` and trust it, the two
documentation servers are not registered and the agent will answer API questions
from memory instead. `codex mcp` lists what is actually registered when in doubt.
