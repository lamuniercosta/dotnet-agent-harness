# The field Keyword (C# 14)

Access the auto-generated backing field in property accessors without declaring it manually.

```csharp
// GOOD — field keyword for validation in auto-property
public class Product
{
    public string Name
    {
        get => field;
        set => field = value?.Trim() ?? throw new ArgumentNullException(nameof(value));
    }

    public decimal Price
    {
        get => field;
        set => field = value >= 0 ? value : throw new ArgumentOutOfRangeException(nameof(value));
    }
}
```

## Lazy Initialization with `field`

```csharp
public class ProductCatalog
{
    // Lazy-load on first access — no manual Lazy<T> or backing field
    public IReadOnlyList<Product> Products
    {
        get => field ??= LoadProducts();
    }

    private static List<Product> LoadProducts() => /* expensive load */;
}
```

## Change Notification with `field`

```csharp
// INotifyPropertyChanged without manual backing fields
public class OrderViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string CustomerName
    {
        get => field;
        set
        {
            if (field == value) return;
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CustomerName)));
        }
    } = "";

    public decimal Total
    {
        get => field;
        set
        {
            if (field == value) return;
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Total)));
        }
    }
}
```
