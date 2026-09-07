# Extension Members (C# 14)

### Extension Members (C# 14)

C# 14 adds `extension` blocks inside static classes. Unlike classic extension methods, they support extension **properties** and **static** extension members — the receiver is declared once for the whole block.

```csharp
// GOOD — extension block (shipped C# 14 syntax)
public static class OrderExtensions
{
    extension(Order order)
    {
        public decimal TotalWithTax => order.Total * 1.2m;

        public bool IsHighValue => order.Total > 1000m;

        public string ToSummary() =>
            $"Order #{order.Id}: {order.Total:C} ({order.Items.Count} items)";
    }

    // Static extension members use the type (no receiver instance)
    extension(Order)
    {
        public static Order Empty => Order.Create("none", [], DateTimeOffset.MinValue);
    }
}

// Callers see them as if declared on Order
if (order.IsHighValue) { /* ... */ }
```

Classic `this`-parameter extension methods still work and coexist — use extension blocks when you need properties or several members on the same receiver.
