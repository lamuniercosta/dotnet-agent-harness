# Retire the Junie OpenRouter launcher for OpenCode

`scripts/local/Invoke-OpenRouterTask.ps1` launched OpenRouter through Junie: it
wrote a per-model custom profile under `~/.junie/models/`, passed the task as
JSON on stdin, kept the key as an environment reference in the profile rather
than a literal, and mapped route-map tiers onto Junie effort and a default
OpenRouter slug. `Test-OpenRouterTask.ps1` was its 43-check dry-run suite.
`CLAUDE.md` told every session that this launcher was the first route for
`/code-review` and `/ship-review`.

That runner is abandoned. The profiles are unmaintained. The section burned
stale Junie mechanics into context on every session. Since 2026-09-14 OpenRouter
is called through **OpenCode**, with Maestri orchestrating the seats.

## Decision

Delete the launcher and its test suite. Stop describing Junie as the OpenRouter
runner. Keep the `openrouter` host rows in `route-map.json` (ADR 0008 — the map
records host and tier, never a runner). Record the retirement here. The
`lint-harness.yml` step that ran the suite is replaced by a key-hygiene grep
gate (owned with that workflow file, not here).

## Accepted cost

Three protections the dry-run suite enforced are gone with the launcher:

1. **Literal-key check.** The suite asserted the generated profile referenced
   the key from the environment and did not contain the actual key value. Partly
   replaced: `.gitleaks.toml` now has a rule for the `sk-or-v1-` OpenRouter key
   prefix. The grep gate still watches the environment-variable *name* in
   tracked files outside the documented exemptions; it does not inspect
   generated profiles on disk.
2. **Profile integrity.** The suite asserted a hand-tuned profile was left
   byte-for-byte untouched and that a stale generated profile was rewritten to
   match the launcher's template. **Not replaced.** OpenCode does not use those
   Junie profiles.
3. **Tier→model consistency.** The suite asserted each route-map tier resolved
   to its documented default slug and Junie effort. **Not replaced.** Concrete
   slugs now live in OpenCode configuration, which this repository does not
   pin.

The placement argument in ADR 0010 is unchanged; a 2026-09-14 addendum there
points at this retirement.
