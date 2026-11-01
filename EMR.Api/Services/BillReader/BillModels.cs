namespace EMR.Api.Services.BillReader;

/// <summary>A word on a bill page with its box (points from the top-left; y grows downwards).</summary>
public sealed record BillWord(string Text, double X0, double Y0, double X1, double Y1, int Page, double Confidence = 1)
{
    public double Xc => (X0 + X1) / 2;
    public double Yc => (Y0 + Y1) / 2;
    public double H => Y1 - Y0;
}

/// <summary>The words of every page, and where they came from (PDF text or OCR).</summary>
public sealed class BillText
{
    public List<BillWord> Words { get; } = [];
    public string Source { get; set; } = "";       // PDF_TEXT | OCR
    public int Pages { get; set; }
    public List<string> Notes { get; } = [];
}

/// <summary>A value read from the bill and how sure the reader is (0-1).</summary>
public sealed class BillField<T>
{
    public T? Value { get; set; }
    public double Confidence { get; set; }
    public static BillField<T> Of(T? value, double confidence) => new() { Value = value, Confidence = value is null ? 0 : confidence };
}

/// <summary>Another Item Master item the printed name might be.</summary>
public sealed record BillAlternative(int ItemId, string ItemName, double Score);

public sealed class BillLine
{
    public int Row { get; set; }
    public string BillText { get; set; } = "";            // the item as printed (for matching and learning)
    public int? ItemId { get; set; }
    public string? ItemName { get; set; }
    public double MatchScore { get; set; }                // 0-1
    public string MatchedBy { get; set; } = "";           // LEARNT | CODE | ML | NONE
    public List<BillAlternative> Alternatives { get; set; } = [];
    public BillField<string> BatchNo { get; set; } = new();
    public BillField<DateTime?> ExpiryDate { get; set; } = new();
    public BillField<decimal?> Mrp { get; set; } = new();
    public BillField<decimal?> Qty { get; set; } = new();
    public BillField<decimal?> FreeQty { get; set; } = new();
    public BillField<decimal?> Rate { get; set; } = new();
    public BillField<decimal?> DiscPercent { get; set; } = new();
    public BillField<decimal?> GstPercent { get; set; } = new();
    public BillField<decimal?> Amount { get; set; } = new();
    public List<string> Notes { get; set; } = [];
}

public sealed class BillReadResult
{
    public string Source { get; set; } = "";
    public int Pages { get; set; }
    public BillField<int?> SupplierId { get; set; } = new();
    public string? SupplierName { get; set; }
    public string? SupplierGstin { get; set; }
    public BillField<string> InvoiceNo { get; set; } = new();
    public BillField<DateTime?> InvoiceDate { get; set; } = new();
    public BillField<decimal?> InvoiceAmount { get; set; } = new();
    public BillField<decimal?> OtherCharges { get; set; } = new();
    public BillField<bool?> IsInterState { get; set; } = new();
    public List<BillLine> Lines { get; set; } = [];
    public List<string> Columns { get; set; } = [];      // the columns found in the item table
    public List<string> Notes { get; set; } = [];
    public decimal? LinesTotal { get; set; }              // sum of the line amounts read (with GST when the bill shows it)
    public List<IDictionary<string, object?>> Items { get; set; } = [];   // the form's item details of the matched items
}
