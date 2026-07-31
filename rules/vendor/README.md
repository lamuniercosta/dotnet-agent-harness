# Vendored rules — third-party

Everything in this directory is **adapted from
[Aaronontheweb/dotnet-cursor-rules](https://github.com/Aaronontheweb/dotnet-cursor-rules) (MIT)**.
It is not authored by this project. Authored rules live in `../pipeline/`.

These are reference *guidelines*, not procedural skills: they shape the code an agent
writes, whereas the pipeline rules govern the process it follows. The gates enforce
thresholds; these files teach the agent how to write code that clears them.

## Contents

| File | Scope | Lines |
|---|---|---|
| `aaron-csharp-coding-style.md` | Idiomatic, functional-leaning C# style and abstraction | 747 |
| `aaron-csharp-testing.md` | Unit/integration testing conventions (xUnit) | 593 |
| `aaron-ci-cd-dotnet-build.md` | `dotnet build` / CI pipeline practices | 866 |
| `aaron-ci-cd-code-signing.md` | Assembly and package signing in CI | 106 |
| `aaron-dotnet-sdk-dependency-management.md` | Central package management, versioning, licensing | 192 |
| `aaron-dotnet-sdk-solution-management.md` | Solution and project organisation | 173 |
| `aaron-dotnet-tools-consuming.md` | Consuming `dotnet tool` via a manifest | 71 |
| `aaron-dotnet-tools-publishing.md` | Publishing a `dotnet tool` | 45 |

**2,793 lines total.** All are `alwaysApply: false` with `globs`, so none of it loads
until a matching file is touched — the reason keeping this much vendored content costs
nothing at rest.

## How each platform loads them

The files retain their original Cursor frontmatter (`description`, `globs`,
`alwaysApply`), which is the canonical form.

**Both platforms load these natively by glob** — no wrapper skills, no reliance on
description matching. Each file carries two frontmatter keys and each platform reads
its own:

| Platform | Installed to | Key |
|---|---|---|
| Cursor | `.cursor/rules/vendor/` | `globs:` |
| Claude Code | `.claude/rules/vendor/` | `paths:` |

Cursor does not read `.claude/rules/`, so one copy cannot serve both. These eight files
are the only thing the installer writes twice, and both copies are regenerated from here
on every install.

### `paths:` is generated, not hand-written

The two keys are **not** interchangeable. Cursor treats `globs: *.cs` as "any `.cs`
anywhere"; Claude treats `paths: *.cs` as **project root only** — `**/*.cs` is what
matches everywhere. Copying the glob list across would silently narrow every rule to
root-level files and look like it worked.

`packs/dotnet/scripts/Sync-VendorRulePaths.ps1` does the translation. Run it after
changing any `globs:` line; `lint-harness.yml` fails the build if the two drift apart.

Two upstream files ship with no globs at all (`tools-consuming`, `tools-publishing`);
the sync script gives them explicit paths rather than an empty list, which would
otherwise make them unconditionally always-on.

## Modifying

Don't edit in place. These are kept verbatim so a future re-sync from upstream stays
possible. If a rule conflicts with this harness, override it in `../pipeline/` — authored
rules take precedence — and record the deviation in the root `NOTICE`.
