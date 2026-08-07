# Agent Harness

The agent harness coordinates local quality gates and reports whether each gate established a trustworthy verdict.

## Gate verdicts

**Pass**:
A gate completed its intended verification and found no blocking issue.
_Avoid_: Clean when the gate examined nothing

**Failure**:
A gate found a blocking issue or could not establish a trustworthy verdict.
_Avoid_: Error as the general verdict

**Skipped**:
A gate intentionally performed no verification because it was disabled or its requested scope matched no inputs.
_Avoid_: Pass, clean

**Could not run**:
A gate attempted verification but could not produce the evidence required for a trustworthy verdict.
_Avoid_: Skipped, pass

## Skill delivery

**Canonical skill**:
The authoritative, host-neutral definition of a harness workflow from which host discovery copies are produced.
_Avoid_: Source skill, master copy

**Discovery copy**:
A host-readable projection of a canonical skill. It is generated and disposable, never edited as an authored source.
_Avoid_: Skill clone, second source

**Authored override**:
A repository-specific skill maintained by hand because its behavior intentionally differs from the canonical workflow.
_Avoid_: Generated exception

**Foreign skill**:
A host discovery entry authored outside the harness bootstrap and therefore ineligible for harness refresh or cleanup.
_Avoid_: Unowned generated skill

**Self-development bootstrap**:
The repo-local operation that creates discovery copies for working on the harness without installing the harness into itself.
_Avoid_: Self-install

**Ownership manifest**:
The local record of discovery copies created by the self-development bootstrap. Only recorded entries are eligible for refresh or cleanup.
_Avoid_: Directory ownership

## Agent delegation

**Agent tier**:
A named cost and capability class assigned to an agent profile according to the cost of a silent miss, not the apparent difficulty of its work.
_Avoid_: Model tier, difficulty level

**Canonical agent profile**:
The authoritative, host-neutral definition of a specialized agent from which host discovery copies are produced.
_Avoid_: Claude agent, source profile

**Agent discovery copy**:
A host-readable projection of a canonical agent profile. It is generated and disposable, never edited as an authored source.
_Avoid_: Agent clone, host-specific source

**Cheap errand**:
A fully specified, one-shot delegated unit of work whose returned answer is much smaller than its input and whose failure is retried inline by the parent.
_Avoid_: Generic subtask, delegation by default

**Writable errand**:
A cheap errand that applies one specified transformation to an explicit set of files exclusively owned by that errand until it returns.
_Avoid_: Open-ended implementation, overlapping edit

## Solution resolution

**Declared solution**:
The solution a human named: the `-Solution` parameter, or `solution:` in `harness.yml` when no parameter is given. Never discovered; a missing path is a hard error.
_Avoid_: Configured solution, explicit solution

**Candidate solution**:
A `.sln` or `.slnx` file the filesystem scan finds when nothing was declared, before any policy applies.
_Avoid_: Found solution, detected solution

**Solution resolution**:
Deciding which single solution a command operates on: declared, else the sole candidate, else the unique repo-root candidate, else refuse. Returns `$null` when the repo has no solution at all.
_Avoid_: Solution discovery, auto-detect

**Build target**:
The path handed to `dotnet build`: the resolved solution, or a lone project when the repo has none.
_Avoid_: Solution (when a `.csproj` may be meant)
