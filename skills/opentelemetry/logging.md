# Source-Generated Logging with OTel

For maximum performance, use `[LoggerMessage]` — eliminates boxing and allocations.

```csharp
public partial class OrderService(ILogger<OrderService> logger)
{
    [LoggerMessage(Level = LogLevel.Information,
        Message = "Processing order {OrderId} for customer {CustomerId}")]
    partial void LogOrderProcessing(Guid orderId, Guid customerId);
}
```

OpenTelemetry logging automatically includes `TraceId` and `SpanId` when an `Activity` is current.
