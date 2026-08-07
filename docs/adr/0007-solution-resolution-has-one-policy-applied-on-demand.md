# Solution resolution has one policy, applied on demand

Three functions resolved solutions independently: `Resolve-BuildTarget` picked
the shallowest candidate silently, `Get-TestProjects` refused on ambiguity, and
`Get-HarnessConfig` refused on ambiguity but did so eagerly at config load —
breaking callers like `new-task-branch.ps1` and `install.ps1` that never asked
about the solution. Three resolvers, two policies, and the eager one took down
unrelated commands as collateral.

## Decision

### One resolver, one policy

`Resolve-Solution` is the single entry point for solution resolution. Its
precedence:

1. A declared solution wins (the `-Explicit` parameter, else `solution:` from
   `harness.yml`). Absolutised and existence-checked; a missing path throws.
2. Exactly one candidate anywhere → that one.
3. Exactly one candidate at the repo root → that one.
4. Multiple candidates with no unique root → throw, listing every candidate and
   `Set 'solution:'` as remediation.
5. Zero candidates → return `$null`. Not an error; callers keep their own
   no-solution fallback.

"The solution at the repo root is the repo's solution" is a rule you can state,
not a heuristic that guesses. It keeps the common monorepo shape
(`App.sln` + `tools/Other.sln`) working without config, and it deletes the
indefensible part of the old shallowest-wins behaviour: `src/App.sln` silently
beating `tools/deep/Other.sln` because depth 2 < depth 3, for no reason a user
could predict.

### Config declares, the resolver discovers

`Get-HarnessConfig` validates what `harness.yml` declares — absolutises and
existence-checks the `solution:` value — but performs no filesystem discovery.
Discovery moves into `Resolve-Solution`, called only by code that needs a
solution. This stops branch creation, installation, and any future config reader
from depending on solution discovery they never asked for.

## Rejected alternatives

**Refuse always.** Consistent with "a gate that cannot determine its scope has
not verified anything," but adopting the harness in a repo with a nested tool
solution means a wall of refusals on day one for something the repo root already
answers unambiguously. The root-level rule is a stated answer, not a default
assumption.

**Keep shallowest-wins.** The cheapest convergence — apply `Resolve-BuildTarget`'s
existing progressive-depth tiebreak to all three call sites. But that makes the
silent-pick behaviour the new answer for `Get-TestProjects` and
`Get-HarnessConfig`, which today refuse. That is a regression against the
direction the repo has been moving: removing silent guesses.

**Middle reading: refuse only when the choice changes what gets verified.** This
requires enumerating projects in every candidate solution and comparing. The
answer is essentially always "yes, they differ" — otherwise why are there two
solutions — so it collapses into "refuse always" with a `dotnet sln list` per
candidate first.

## Accepted cost

A repo whose root `.sln` is a stale aggregate that nobody builds will be
silently verified against the wrong scope. This is the trade for adoptability:
refusing would be correct but impractical, and the stale-aggregate scenario is
rarer than the nested-tool one it would penalise. The cost is documented here so
a future reader can re-evaluate if stale aggregates become common.

A same-basename `.sln` / `.slnx` pair at the root — common during `dotnet sln
migrate` — is two candidates and refuses. The two files can and do diverge after
migration, and picking one silently is the guess the policy exists to prevent.

## Consequences

Analyzer, complexity, and InspectCode gates now honour `solution:` from
`harness.yml`, which they previously ignored. The `bin|obj|node_modules|artifacts`
exclusion applies to all candidate scans, closing a gap in `Get-HarnessConfig`'s
glob.

One repo shape breaks: a repo with solutions only at depth > 0 and no unique
root candidate (e.g. `src/App.sln` + `tools/Other.sln`) now refuses where the
analyzer gates previously built `src/App.sln` silently. Remediation is one line:
`solution: src/App.sln` in `harness.yml`.
