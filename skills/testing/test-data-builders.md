# Test Data Builders

```csharp
public class OrderBuilder
{
    private string _customerId = "default-customer";
    private List<OrderItem> _items = [new("product-1", 1, 9.99m)];
    private OrderStatus _status = OrderStatus.Pending;

    public OrderBuilder WithCustomer(string customerId)
    {
        _customerId = customerId;
        return this;
    }

    public OrderBuilder WithItems(params OrderItem[] items)
    {
        _items = [..items];
        return this;
    }

    public OrderBuilder WithStatus(OrderStatus status)
    {
        _status = status;
        return this;
    }

    public Order Build() => Order.Create(_customerId, _items, _status);
}

// Usage in tests
var order = new OrderBuilder()
    .WithCustomer("vip-customer")
    .WithStatus(OrderStatus.Confirmed)
    .Build();
```
