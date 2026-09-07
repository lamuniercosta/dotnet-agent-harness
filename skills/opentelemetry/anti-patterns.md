# Anti-patterns

## Anti-patterns

### Don't Create Meters Per Request

```csharp
// BAD — new Meter per request causes memory leaks
public void HandleRequest()
{
    var meter = new Meter("MyApp");
    meter.CreateCounter<int>("requests").Add(1);
}

// GOOD — singleton via IMeterFactory
public class MyMetrics(IMeterFactory meterFactory)
{
    private readonly Counter<int> _requests =
        meterFactory.Create("MyApp").CreateCounter<int>("myapp.requests");
    public void RequestHandled() => _requests.Add(1);
}
```

### Don't Skip Null Checks on Activity

```csharp
// BAD — NullReferenceException when no listener is attached
using var activity = source.StartActivity("Work");
activity.SetTag("key", "value");

// GOOD — null-safe
activity?.SetTag("key", "value");
```

### Don't Use High-Cardinality Metric Tags

```csharp
// BAD — unbounded cardinality causes memory explosion in collectors
_counter.Add(1, new("request.id", Guid.NewGuid().ToString()));
_counter.Add(1, new("user.id", userId));

// GOOD — low-cardinality dimensions only
_counter.Add(1, new("http.method", "GET"), new("http.status_code", 200));
```

### Don't Mix UseOtlpExporter with AddOtlpExporter

```csharp
// BAD — throws NotSupportedException at runtime
builder.Services.AddOpenTelemetry()
    .UseOtlpExporter()
    .WithTracing(t => t.AddOtlpExporter());

// GOOD — use one approach
builder.Services.AddOpenTelemetry().UseOtlpExporter();
```

### Don't Forget to Register Custom Sources

```csharp
// BAD — activities silently dropped (no listener registered)
var source = new ActivitySource("MyApp.Custom");
using var activity = source.StartActivity("Work"); // null!

// GOOD — register in the tracing builder
otel.WithTracing(t => t.AddSource("MyApp.Custom"));
otel.WithMetrics(m => m.AddMeter("MyApp.Custom"));
```
