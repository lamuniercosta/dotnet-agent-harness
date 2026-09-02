# The harness does not project its own skills

ADR 0005 gave this repository a self-development bootstrap:
`Sync-SelfSkills.ps1` rendered every canonical skill into ignored
`.claude/skills/` and `.agents/skills/` discovery copies through the same paths
`install.ps1` uses for consumers, recording ownership in an ignored manifest so
refresh and cleanup could never touch the authored `start-issue` override or a
foreign skill. The premise was that the harness should exercise the same
invocation surface a consumer gets.

That premise does not hold here, and the projection has been actively harmful.

**The skills do not fit this repository.** The analysis and implementation
commands — `/implement`, `/code-review`, `/refactor`, `/verify`, `/architect`,
the speckit chain — bottom out in C# and Roslyn gates. This repository contains
no production C#; its only C# is `fixtures/BadCode/`, which is deliberately
broken and which `fixture-gates.yml` asserts every gate rejects. Running those
commands here spends tokens to analyse a language that is not present. The
distribution question they were projected to answer is already answered by
`fixture-gates.yml` and the grep gates in `lint-harness.yml`, which test the
shipped artifacts directly rather than by invoking them.

**A resolvable command outranks a written instruction.** The projections made 26
harness commands invocable in this checkout, and root `CLAUDE.md` mandated
`/grill-with-docs` as part of intake. An agent briefed not to use the harness
pipeline on the harness still ran it, because the always-loaded override file
told it to and the command resolved. Instructions carried in a role prompt, a
setup brief or a conversation lose to an instruction carried in `CLAUDE.md` next
to a command that works. The only reliable way to stop a command being run is
for it not to resolve.

**The projection was a second thing to keep in ripple.** This repository's
characteristic failure is a change landing in `skills/` but not in `rules/`, the
adapters, the `install.ps1` manifest, or the lint gates. The bootstrap added
another downstream copy to that chain, plus its own test, its own CI step, its
own manifest, and its own `.gitignore` negations — all to reproduce something
`install.ps1` already does for the audience that needs it.

## Decision

This repository does not project its skills into any host discovery tree.
`skills/`, `rules/`, `adapters/` and `.claude/agents/` are authored sources that
ship to consumers; they are not commands available here. `.claude/skills/` and
`.agents/` are ignored outright so a stray sync cannot reintroduce them.

Removed: `scripts/local/Sync-SelfSkills.ps1`, `scripts/local/Test-SelfSkills.ps1`
and its `lint-harness.yml` step, `scripts/local/.self-skills-manifest.json`, the
generated discovery copies, and the `/start-issue` authored override in both
trees. Issue intake in this repository is now the two commands `CLAUDE.md`
documents — `packs/dotnet/scripts/new-task-branch.ps1` and
`scripts/local/Set-IssueInProgress.ps1` — run directly, with no skill wrapper
and no `/grill-with-docs` handoff.

This supersedes ADR 0005 entirely. It also supersedes ADR 0003 **for this
repository only**: the generated `.agents/` copy remains how Codex skills reach
consumers, and `install.ps1` is unchanged. Nothing here alters what an adopting
repository receives — `install.ps1` still refuses the harness root, still copies
from `skills/`, and still sources its `CLAUDE.md` and `AGENTS.md` from
`adapters/`.

## Accepted cost

Nobody dogfoods the invocation surface any more. A skill that renders but fails
when invoked would not be caught here; it would be caught by a consumer. That
was already largely true — the projections were rendered and rarely run — and
the alternative was paying for C# analysis this repository cannot use while
leaving agents an instruction they were structurally likely to disobey.

If a harness command still resolves in this checkout, it is coming from an
installed plugin such as `dotnet-claude-kit`, not from this repository. That is
outside this repository's control and outside this decision's scope.
