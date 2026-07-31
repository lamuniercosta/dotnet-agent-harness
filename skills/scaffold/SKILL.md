---
name: scaffold
description: Scaffold a complete feature slice matching the repo's existing architecture — request/command type, handler, validator, DTOs, DI registration, and tests — never a half-feature. Use for "scaffold", "create feature", "add command", "add query", "new endpoint", "add validator", "generate feature".
disable-model-invocation: true
---

# Scaffold

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT).

## What

Generates a complete, consistent feature slice — **never half a feature**. Every scaffold includes the request type, its handler, a validator (when input needs validating), DI registration, and at least one test at the right seam.

It **matches the repo's existing architecture rather than imposing one**. This skill has no preferred architecture: CQRS handlers, minimal-API endpoints, MediatR, vertical slices, and layered services are all fine — whichever the repo already uses. Consistency with the neighbouring code beats any pattern this skill could recommend.

## When

- "Scaffold / create / add" a command, query, endpoint, validator, or processing step
- Starting a new feature after `/speckit-tasks`, or during `/implement`
- Any time you want a working skeleton wired into DI and tests

## How

### Step 1 — Learn the architecture (never skip)

Run `/convention-learner`, or at minimum read the **two nearest siblings** to what you're adding. Determine and write down:

- The organising principle — layered, vertical slice, or modular monolith
- The dispatch mechanism — hand-rolled `ICommandHandler`, MediatR `IRequestHandler`, direct minimal-API delegates, controller actions
- Where DI registration lives, and whether it is manual or assembly-scanned
- Naming and access conventions — `sealed`, interface-in-same-file, suffixes, `CancellationToken ct = default`, guard-clause style

**If two sibling features disagree, follow the newer one and say so.**

### Step 2 — Clarify scope
Confirm anything `tasks.md`/`plan.md` hasn't already answered: feature name; command vs query vs background step; inputs and invariants; which module/folder; how it is triggered (HTTP endpoint, message handler, scheduled job).

### Step 3 — Generate the slice

Place each artifact where the repo already puts that kind of artifact. Derive the paths in step 1 — do not assume this table's example layout:

| Artifact | Typical home |
|---|---|
| Request/command type + handler | beside its siblings in the feature or command folder |
| Handler abstraction | the existing one — do not introduce a new dispatch abstraction |
| Validator | wherever validators live, wired where mutating input enters |
| DTOs / entities | records shaped for the consumer, not 1:1 internal mirrors |
| Client (new integration) | matching the repo's client convention (often interface + `sealed` impl in one file) |
| DI registration | the repo's composition root |
| Telemetry | the repo's existing constants and abstraction (see `/opentelemetry`) |
| Unit / property tests | `[Trait("Category","Property")]` for pure logic |
| Integration tests | `WebApplicationFactory` / Testcontainers |
| Acceptance scenario *(opt-in)* | `specs/<feature>/acceptance/*.feature` via `/gherkin` |

Shape the code to match what is already there. Illustrative only — the dispatch interface, DI style, and naming all come from step 1:

```csharp
public sealed record CreateWidgetCommand(string Name, Guid TenantId);

public sealed class CreateWidgetCommandHandler(IWidgetClient client, ITelemetry telemetry)
    : ICommandHandler<CreateWidgetCommand, WidgetResponse>
{
    public async Task<WidgetResponse> HandleAsync(CreateWidgetCommand command, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        // ...
    }
}
```

### Step 4 — Completeness checklist (mandatory)
- [ ] Request type + one-per-operation `sealed` handler using the repo's existing abstraction
- [ ] Validator with meaningful rules, wired where mutating input enters
- [ ] DTOs/entities as records shaped for the consumer
- [ ] DI registered in the repo's composition root
- [ ] `CancellationToken` on every async method **and passed to every async call**
- [ ] Telemetry via the repo's constants (no inline span strings), no secrets or PII in tags
- [ ] `TimeProvider` for time, injected seeded `Random` for randomness — `DateTime.Now` is banned by `BannedSymbols.txt`
- [ ] At least one test at the correct seam
- [ ] No explanatory comments (`coding-conventions`)

A slice missing any of these is not scaffolded, it is started. Report it as incomplete rather than done.

### Step 5 — Verify

Run `/verify`, or at minimum:

```powershell
dotnet build
dotnet test --filter "FullyQualifiedName~{Feature}"
./scripts/run-roslyn-analyzers.ps1
./scripts/run-cyclomatic-complexity.ps1
```

Fix and re-run before reporting done. The implementation complexity threshold is 15; `/refactor` later tightens it to 6 — write it close to the tighter bar now rather than paying for it twice.

## Anti-patterns

- **Introducing a new architecture.** Adding MediatR to a repo with hand-rolled handlers, or EF Core patterns to a repo using a document driver, because the skill's example did it that way.
- Registering handlers ad hoc instead of in the composition root
- A client whose interface sits in a separate file when the repo keeps both together
- Scaffolding tests against a mocked data-access interface when the behaviour needs real serialisation — use Testcontainers
- Generating the handler and calling it done, with no validator, DI, or test

## Related

- `/convention-learner` — detect conventions before generating
- `/implement` — the pipeline stage this supports
- `/verify` — prove the slice builds and passes the gates
