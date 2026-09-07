---
name: modern-csharp
description: >
  Modern C# language features for .NET 10 and C# 14. Covers primary constructors,
  collection expressions, the field keyword, extension members, records, pattern
  matching, spans, and raw string literals.
  Load this skill when writing any new C# code, reviewing existing code for
  modernization, using "modern C#", "C# 14", "primary constructor", "collection
  expression", "records", "pattern matching", "span", "field keyword", or
  "extension members".
---

# Modern C#

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT).

**Check the language version first.** Every repo targets the SDK and `LangVersion` pinned in its `Directory.Build.props` / `global.json`. Treat any feature needing a newer compiler (the `field` keyword, `extension` blocks) as aspirational until that version supports it — read the file, don't assume the latest.

**Repo conventions win over every example below.** The `coding-conventions` rule mandates `sealed` by default, file-scoped namespaces, interface-in-same-file, naming by functionality rather than vendor, and **no explanatory comments**. Where a repo's own `CLAUDE.md`/`AGENTS.md` or `.editorconfig` disagrees with this skill, the repo is right.

## Core Principles

1. **Use the newest stable features** — C# 14 is the target. Prefer language-level constructs over library workarounds.
2. **Readability over cleverness** — Pattern matching and expression-bodied members improve readability when used appropriately; deeply nested patterns do not.
3. **Value types where possible** — Prefer `record struct`, `Span<T>`, and stack allocation to reduce GC pressure.
4. **Immutability by default** — Use `record`, `readonly`, `init`, and `required` to make illegal states unrepresentable.

## Patterns

### Well-Known Features Quick Reference

| Feature | Usage | Example |
|---------|-------|---------|
| Primary constructors | DI injection, eliminate field assignments | `public class OrderService(IOrderRepo repo, TimeProvider clock) { }` |
| Collection expressions | `[]` for all collection types + spread | `List<string> names = ["Alice", "Bob"];` / `int[] all = [..a, ..b, 99];` |
| Records | DTOs, value objects, immutable data | `public record CreateOrderRequest(string CustomerId, List<OrderItem> Items);` |
| `readonly record struct` | Small stack-allocated value types | `public readonly record struct Money(decimal Amount, string Currency);` |
| Pattern matching | Switch expressions, list/property patterns | `order switch { { Total: > 1000 } => "Premium", _ => "Standard" };` |
| List patterns | Deconstruct arrays/lists | `items switch { [] => "Empty", [var x] => $"One: {x}", [var f, .., var l] => $"{f}..{l}" };` |
| `Span<T>` | Zero-allocation slicing | `ReadOnlySpan<char> trimmed = input.Trim(); int.TryParse(trimmed[4..], out id);` |
| Raw string literals | Multi-line SQL, JSON, XML | `var sql = """ SELECT ... """;` / interpolated: `$$""" {"id": "{{id}}"} """;` |
| `required` members | Enforce initialization | `public required string ConnectionString { get; init; }` |
| `is` pattern + extraction | Null/type/property check | `if (result is { IsSuccess: true, Value: var order }) { ... }` |

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| DTO / API contract | `record` (reference type) |
| Small value object (2-3 fields) | `readonly record struct` |
| Service with DI | Primary constructor |
| Collection creation | Collection expression `[]` |
| Property with validation | `field` keyword |
| Multi-line string (SQL, JSON) | Raw string literal `"""` |
| Slicing strings/arrays | `Span<T>` |
| Type checking + extraction | Pattern matching with `is` / `switch` |
| Enforced initialization | `required` modifier |
| Adding methods to external types | Extension members |

## Topics

- **The field Keyword** — C# 14 field keyword, all three sub-patterns. Read ./field-keyword.md in this skill's directory
- **Extension Members** — C# 14 extension blocks. Read ./extension-members.md in this skill's directory
- **Anti-patterns** — obsolete patterns, over-pattern-match, var misuse. Read ./anti-patterns.md in this skill's directory
