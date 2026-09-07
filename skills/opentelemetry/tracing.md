# Custom ActivitySource for Distributed Tracing

### Custom ActivitySource for Distributed Tracing

```csharp
public sealed class OrderService(ILogger<OrderService> logger)
{
    private static readonly ActivitySource Source = new("MyApp.Orders");

    public async Task<Order> ProcessOrderAsync(CreateOrderRequest request, CancellationToken ct)
    {
        using var activity = Source.StartActivity("ProcessOrder", ActivityKind.Internal);
        activity?.SetTag("order.customer_id", request.CustomerId);

        try
        {
            await ValidateOrder(request, ct);
            activity?.AddEvent(new ActivityEvent("OrderValidated"));

            var order = await SaveOrder(request, ct);
            activity?.SetTag("order.id", order.Id.ToString());
            activity?.SetStatus(ActivityStatusCode.Ok);
            return order;
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);
            throw;
        }
    }
}
```

Register the source: `.AddSource("MyApp.Orders")` in the tracing builder.
