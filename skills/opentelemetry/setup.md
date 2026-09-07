# Full Setup with All Three Signals + Aspire Dashboard

## Patterns

### Full Setup with All Three Signals

```csharp
// Program.cs
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService(
            serviceName: builder.Environment.ApplicationName,
            serviceVersion: "1.0.0"))
    .WithTracing(tracing => tracing
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddEntityFrameworkCoreInstrumentation()
        .AddSource("MyApp.Orders"))
    .WithMetrics(metrics => metrics
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddMeter("MyApp.Orders"))
    .WithLogging()             // no per-signal exporter here —
    .UseOtlpExporter();        // UseOtlpExporter covers all three signals

// UseOtlpExporter replaces per-signal AddOtlpExporter calls. Never combine
// the two — mixing them throws NotSupportedException (see Anti-patterns).
```

The OTLP endpoint defaults to `http://localhost:4317` (gRPC). Override via:
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317
OTEL_SERVICE_NAME=MyApp.Api
```

### Aspire Dashboard for Local Development

Run the standalone Aspire Dashboard without Aspire orchestration:

```bash
docker run --rm -it -p 18888:18888 -p 4317:18889 \
    mcr.microsoft.com/dotnet/aspire-dashboard:latest
```

Then point your app at it:
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

Dashboard UI is at `http://localhost:18888`.
