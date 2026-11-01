namespace EMR.Api.Models;

// Pharmacy > Purchase (SQLScripts/2358). Lines travel as JSON text to the save procedures (OPENJSON).

public record PhIndentSaveRequest(int Id, int CompanyId, int BranchId, int UserId, DateTime DocDate, string? Priority, string? Remarks, string Lines);

public record PhDocActionRequest(int Id, int CompanyId, int BranchId, int UserId, string Action, string? Remarks);

public record PhPoSaveRequest(int Id, int CompanyId, int BranchId, int UserId, DateTime DocDate, int SupplierId, int? IndentId, DateTime? ExpectedDate,
    bool IsInterState, string? Terms, string? Remarks, decimal Taxable, decimal Gst, decimal Net, bool IsDirect, string? InvoiceNo, DateTime? InvoiceDate,
    decimal? InvoiceAmount, decimal OtherCharges, string Lines);

public record PhPoUndoDirectRequest(int PoId, int GrnId);

public record PhPoEmailedRequest(int PoId, string Email);

public record PhGrnSaveRequest(int Id, int CompanyId, int BranchId, int UserId, DateTime DocDate, int SupplierId, int? PoId, string InvoiceNo, DateTime InvoiceDate,
    decimal InvoiceAmount, bool IsInterState, decimal OtherCharges, string? Remarks, string Lines, int? StoreId = null);

public record PhGrnAttachRequest(int CompanyId, int BranchId, int GrnId, string Path, string Name);

public record PhDocRefRequest(int CompanyId, int BranchId, int Id, int UserId);

public record PhPurchaseReturnSaveRequest(int Id, int CompanyId, int BranchId, int UserId, DateTime DocDate, int SupplierId, int ReasonId, bool IsInterState,
    string? Remarks, string Lines, int? StoreId = null);

public record PhSupplierPaymentSaveRequest(int CompanyId, int BranchId, int UserId, int SupplierId, DateTime Date, string Mode, string? Reference, string? Remarks, string Alloc);

/// <summary>A document with its lines and the item details of those lines (each a row of column / value).</summary>
public class PhDocResult
{
    public IDictionary<string, object?>? Header { get; set; }
    public List<IDictionary<string, object?>> Lines { get; set; } = [];
    public List<IDictionary<string, object?>> Items { get; set; } = [];
}

/// <summary>Result of a save / action / posting: the id or document number, or the message to show.</summary>
public class PhResult
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public string? Error { get; set; }
}
