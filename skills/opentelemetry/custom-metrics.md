# Custom Metrics with IMeterFactory + Multi-Dimensional Tags

## Custom Metrics with IMeterFactory

Register a metrics class as a singleton. `IMeterFactory` handles `Meter` disposal through DI.

```csharp
public sealed class OrderMetrics
{
    private readonly Counter<int> _ordersCreated;
    private readonly Histogram<double> _orderDuration;
    private readonly UpDownCounter<int> _activeOrders;
    private readonly Gauge<double> _queueDepth;

    public OrderMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create("MyApp.Orders");

        _ordersCreated = meter.CreateCounter<int>(
            "myapp.orders.created", "{orders}", "Number of orders created");

        _orderDuration = meter.CreateHistogram<double>(
            "myapp.orders.duration", "s", "Order processing duration",
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [0.01, 0.05, 0.1, 0.5, 1, 5, 10]
            });

        _activeOrders = meter.CreateUpDownCounter<int>(
            "myapp.orders.active", "{orders}", "Currently active orders");

        _queueDepth = meter.CreateGauge<double>(
            "myapp.orders.queue_depth", "{items}", "Current queue depth");
    }

    public void OrderCreated() => _ordersCreated.Add(1);
    public void RecordDuration(double seconds) => _orderDuration.Record(seconds);
    public void OrderStarted() => _activeOrders.Add(1);
    public void OrderCompleted() => _activeOrders.Add(-1);
    public void SetQueueDepth(double depth) => _queueDepth.Record(depth);
}

// Registration
builder.Services.AddSingleton<OrderMetrics>();
```

## Multi-Dimensional Metric Tags

Three or fewer tags are allocation-free. For more, use `TagList`.

```csharp
// Allocation-free (3 or fewer tags)
_ordersCreated.Add(1,
    new KeyValuePair<string, object?>("order.type", "standard"),
    new KeyValuePair<string, object?>("payment.method", "credit_card"));

// 4+ tags — use TagList to avoid allocations
var tags = new TagList
{
    { "order.type", "standard" },
    { "payment.method", "credit_card" },
    { "region", "us-east" },
    { "priority", "high" }
};
_ordersCreated.Add(1, tags);
```
