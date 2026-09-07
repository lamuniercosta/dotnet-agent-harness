# Telemetry Integration

### Telemetry Integration

```csharp
builder.Services.AddResiliencePipeline("monitored", (builder, context) =>
{
    // Polly v8 emits metrics via System.Diagnostics.Metrics automatically.
    // ConfigureTelemetry wires structured logging for strategy events.
    builder
        .ConfigureTelemetry(new TelemetryOptions
        {
            LoggerFactory = context.ServiceProvider.GetRequiredService<ILoggerFactory>()
        })
        .AddRetry(new RetryStrategyOptions { MaxRetryAttempts = 3 })
        .AddCircuitBreaker(new CircuitBreakerStrategyOptions())
        .AddTimeout(TimeSpan.FromSeconds(10));
});

// In Program.cs — wire up OpenTelemetry to capture Polly metrics
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics.AddMeter("Polly"));
```
