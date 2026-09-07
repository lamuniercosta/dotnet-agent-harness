---
name: opentelemetry
description: >
  OpenTelemetry observability for .NET 10 applications. Covers traces, metrics,
  and logs using the OpenTelemetry SDK with OTLP export. Includes custom
  ActivitySource, IMeterFactory metrics, resource configuration, and Aspire
  Dashboard integration.
  Load this skill when setting up distributed tracing, custom metrics, OTLP
  export, or when the user mentions "OpenTelemetry", "OTLP", "traces", "spans",
  "Activity", "ActivitySource", "metrics", "IMeterFactory", "Meter", "Counter",
  "Histogram", "Gauge", "telemetry", "observability", "distributed tracing",
  "OTEL", or "Aspire Dashboard".
---

# OpenTelemetry

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT).

## Check for an existing setup first

Before adding any telemetry, search the repo for an existing `ActivitySource`, `Meter`, or telemetry abstraction. Most codebases that have OpenTelemetry at all have exactly one wiring point, and a second parallel `ActivitySource` fragments the trace — spans land in different sources and no backend stitches them back together.

If a setup exists, extend it rather than duplicating it:

- **Spans** — go through the repo's telemetry abstraction if it has one, not a raw `ActivitySource`.
- **Span and tag names** — use the repo's constants file; never inline string literals. Inconsistent names are unqueryable, and a renamed literal silently breaks dashboards.
- **Cross-process context** — propagate trace context explicitly across any queue or broker boundary (inject on send, extract on receive). Context does not cross a message broker on its own.
- **Naming by functionality** — per the `coding-conventions` rule, name spans and types by what they do (`Queue.Send`), never by vendor (`ServiceBus.Send`). Swapping the transport should not rename the span.
- **No secrets or PII in attributes** — this is a gate-3 check in `/ship-review`, and attributes are far more widely exported than logs.

The guidance below is the reference for SDK wiring, custom metrics, and OTLP export when starting fresh or extending an existing setup.

## Core Principles

1. **Three pillars, one setup** — Configure traces, metrics, and logs through a single `AddOpenTelemetry()` call. Use `UseOtlpExporter()` for cross-cutting export to any OTLP-compatible backend.
2. **Use `IMeterFactory` for metrics** — Never create `Meter` instances with `new`. The factory manages lifetime through DI and prevents leaks.
3. **Null-safe activities** — `StartActivity()` returns `null` when no listener is attached. Always use `?.` when setting tags or events.
4. **Environment variables over code** — Use `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` so deployments control telemetry routing without code changes.
5. **Low-cardinality metric tags** — Keep metric tag combinations under ~1000 per instrument. Use span attributes or logs for high-cardinality data like user IDs or request IDs.

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| Full observability setup | `AddOpenTelemetry()` with all three signals + `UseOtlpExporter()` |
| Custom business metrics | `IMeterFactory` + singleton metrics class |
| Custom trace spans | `ActivitySource` + `StartActivity()` |
| Local development backend | Aspire Dashboard standalone container |
| Production backend | OTel Collector as intermediary to Grafana/Datadog/etc. |
| Sampling in production | `OTEL_TRACES_SAMPLER=parentbased_traceidratio` with 10% ratio |
| High-performance logging | `[LoggerMessage]` source generator |
| Metric tag cardinality | Max ~1000 combinations per instrument |
| Environment configuration | `OTEL_*` env vars (also work via `appsettings.json`) |

## Topics

- **Full Setup** — all three signals and Aspire Dashboard. Read ./setup.md in this skill's directory
- **Custom Metrics** — IMeterFactory and multi-dimensional tags. Read ./custom-metrics.md in this skill's directory
- **Custom ActivitySource** — distributed tracing. Read ./tracing.md in this skill's directory
- **Source-Generated Logging** — LoggerMessage with OTel. Read ./logging.md in this skill's directory
- **Anti-patterns** — meters per request, null checks, cardinality, mixed exporters, unregistered sources. Read ./anti-patterns.md in this skill's directory
