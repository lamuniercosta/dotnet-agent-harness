# Changelog

Notable changes to `dotnet-agent-harness`. The version here is written into a
consuming repo's `harness.yml` as `harnessVersion`, so an install reports
`0.1.0 -> 0.2.0` rather than overwriting silently.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [semantic versioning](https://semver.org/), where a **major** bump
means a consuming repo's gates may start failing on code that previously passed.

## [0.1.0] — 2026-07-31

First release. Extracted from a private, gitignored Cursor setup and generalised
to run on both Cursor and Claude Code with no paid service.

### The pipeline
- 11 stages from issue to PR, with three human approval gates
- Mandatory `/grill-with-docs` alignment before any spec is written
- Chains into [Spec Kit](https://github.com/github/spec-kit) `0.8.14` via a
  15-line `extensions.yml` — the entire coupling

### The gates
Six checks, all running locally after `dotnet tool restore`, none needing an
account:

| Gate | Default |
|---|---|
| Roslyn analyzers, incl. the security families | warning+ |
| Cyclomatic complexity | ≤ 15 implementing, ≤ 6 at refactor |
| InspectCode inspections and duplication | zero on changed files |
| Mutation score | ≥ 80% |
| Property tests | required for pure logic |
| Vulnerable packages | zero, incl. transitive |

- **Exit contract: 0 = pass, 1 = fail, 2 = SKIPPED.** A gate that verified
  nothing reports 2 and is never folded into a green verdict.
- `AnalysisMode=All` enables CA2100 / CA3xxx / CA5xxx, which are off by default —
  this is what replaces the local half of a hosted static-analysis service.
- A gate whose analyzer is not wired exits 1 with remediation rather than
  reporting a pass it did not earn.

### Configuration
- `harness.yml` is the entire config surface; thresholds live there and are
  rendered into `CodeMetricsConfig.txt`, `stryker-config.json`, the
  `.editorconfig` severities, and the constitution's Verification Gates article
- Parsed by a strict subset reader — **unknown keys are a hard error**, so a
  typo cannot silently revert a threshold to its default

### Both platforms
- 25 skills and 5 agents in `.claude/`, read natively by Cursor and Claude Code
- Vendored .NET rules load by glob on both: `globs:` for Cursor,
  generated `paths:` for Claude Code
- Only five files differ between platforms — the adapters

### Verification
- `fixtures/BadCode` carries one deliberate violation per gate; CI asserts every
  gate exits non-zero on the broken state and zero on the fixed one
- Self-tests for the guard hook (23 checks) and the config parser (14 checks)
- The guard's suite includes the escaped-quote payload that defeats a
  `grep`-based hook

### Known limitations
- The vulnerable-package gate is proven against a canned advisory document, not
  a real CVE — see `fixtures/BadCode/README.md`
- Gherkin mutation has no fixture; acceptance tests are opt-in and the gate
  reports SKIPPED when no `.feature` files exist
- Agent frontmatter carries `readonly:` (Cursor) and `tools:` (Claude Code);
  neither platform documents ignoring the other's key. See the pre-publish
  checklist in `CONTRIBUTING.md`

[0.1.0]: https://github.com/lamuniercosta/dotnet-agent-harness/releases/tag/v0.1.0
