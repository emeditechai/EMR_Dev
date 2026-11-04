using System.Text.Json;
using EMR.Web.ApiClients;

namespace EMR.Web.Services;

// Pharmacy > Purchase (SQLScripts/2344): Purchase Indent -> Purchase Order -> GRN -> Purchase Return, Supplier Payments.
// Quantities on indent / PO / GRN are in purchase units (packs); stock and returns are in sale units.
// Amounts are always worked out here (the page only previews them); GRN and return posting is in stored procedures.

// ── Auto Reorder / supplier schemes (SQLScripts/2403) ──
public class PhReorderSettings
{
    public bool Enabled { get; set; }
    public int SalesDays { get; set; }
    public int SafetyDays { get; set; }
    public int CoverDays { get; set; }
    public bool GrnNotRequired { get; set; }
}

public class PhReorderRow
{
    public int ItemId { get; set; }
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string? PurchaseUom { get; set; }
    public int ConversionQty { get; set; }
    public decimal GstPercent { get; set; }
    public decimal StockPacks { get; set; }
    public decimal PendingPoQty { get; set; }
    public decimal AvgDaily { get; set; }
    public decimal? DaysOfStock { get; set; }
    public int LeadDays { get; set; }
    public decimal ReorderLevel { get; set; }
    public decimal MaxQty { get; set; }
    public decimal ReorderPoint { get; set; }
    public decimal OrderUpTo { get; set; }
    public decimal SuggestedQty { get; set; }
    public decimal? LastMrp { get; set; }
    public int? SupplierId { get; set; }
    public string? SupplierName { get; set; }
    public decimal? Rate { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal FreeQty { get; set; }
    public string? SchemeText { get; set; }
}

public class PhReorderLine
{
    public int ItemId { get; set; }
    public int SupplierId { get; set; }
    public decimal Qty { get; set; }
    public decimal Rate { get; set; }
    public decimal DiscPercent { get; set; }
}

public class PhReorderCreated
{
    public int PoId { get; set; }
    public string? SupplierName { get; set; }
    public int Lines { get; set; }
    public decimal NetAmount { get; set; }
    public string? Error { get; set; }
}

public class PhSchemeFree
{
    public decimal FreeQty { get; set; }
    public string? SchemeText { get; set; }
    public bool AutoApply { get; set; }
}

public class PhTxnItem
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }            // sale units at this branch
    public decimal ReorderLevel { get; set; }     // packs (branch value, else item default)
    public decimal MaxQty { get; set; }
    public decimal PendingPoQty { get; set; }     // packs ordered, not yet received
    public decimal? LastRate { get; set; }        // per pack, from the last GRN
    public decimal? LastMrp { get; set; }
    public string? LastSupplier { get; set; }
}

public class PhDocListRow
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; }
    public string? Party { get; set; }
    public string? Ref { get; set; }
    public string Status { get; set; } = "";
    public int Lines { get; set; }
    public decimal Amount { get; set; }
    public string? Extra { get; set; }
    public DateTime? DueDate { get; set; }
    public decimal Balance { get; set; }
}

public class PhDocLine
{
    public int LineId { get; set; }
    public int ItemId { get; set; }
    public string? ItemName { get; set; }
    public string? ItemCode { get; set; }
    public string? FormShort { get; set; }
    public string? PurchaseUom { get; set; }
    public string? SaleUom { get; set; }
    public int ConversionQty { get; set; } = 1;
    public decimal Qty { get; set; }
    public decimal FreeQty { get; set; }
    public decimal Rate { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal GstPercent { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal GstAmount { get; set; }
    public string? Remarks { get; set; }
    public decimal Stock { get; set; }
    // GRN
    public int? PoDtlId { get; set; }
    public string? BatchNo { get; set; }
    public DateTime? MfgDate { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal PendingQty { get; set; }       // PO: ordered - received
    public decimal ReceivedQty { get; set; }
    // return
    public int? BatchId { get; set; }
}

public class PhDoc
{
    public int Id { get; set; }
    public int? StoreId { get; set; }            // GRN: store received into; return: store it leaves (SQLScripts/2364)
    public string? StoreName { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; } = DateTime.Today;
    public string Status { get; set; } = "DRAFT";
    public int? SupplierId { get; set; }
    public string? SupplierName { get; set; }
    public int? RefId { get; set; }              // PO: indent; GRN: PO
    public string? RefNo { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string? Priority { get; set; }
    public bool IsInterState { get; set; }
    public bool IsDirect { get; set; }            // PO entered with GRN Not Required: approval posts the stock
    public string? InvoiceNo { get; set; }
    public DateTime? InvoiceDate { get; set; }
    public decimal InvoiceAmount { get; set; }
    public decimal OtherCharges { get; set; }
    public int? ReasonId { get; set; }
    public string? Terms { get; set; }
    public string? Remarks { get; set; }
    public string? ActionRemarks { get; set; }
    public decimal TaxableAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOff { get; set; }
    public decimal NetAmount { get; set; }
    public DateTime? DueDate { get; set; }
    public string? AttachmentPath { get; set; }
    public string? AttachmentName { get; set; }
    public string? EmailedTo { get; set; }
    public DateTime? EmailedDate { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public List<PhDocLine> Lines { get; set; } = [];
}

public class PhSupplierInfo
{
    public int SupplierId { get; set; }
    public string SupplierName { get; set; } = "";
    public string? Gstin { get; set; }
    public string? Email { get; set; }
    public bool ReceiveIndentEmail { get; set; }   // SQLScripts/2413
    public int CreditDays { get; set; }
    public DateTime? DrugLicenceValidTo { get; set; }
    public bool IsInterState { get; set; }
    public string? Warning { get; set; }
}

public class PhBatchPick
{
    public int BatchId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal RatePerUnit { get; set; }       // purchase rate per sale unit
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public string? SupplierName { get; set; }
}

public class PhPayable
{
    public int GrnId { get; set; }
    public string GrnNo { get; set; } = "";
    public string InvoiceNo { get; set; } = "";
    public DateTime InvoiceDate { get; set; }
    public DateTime? DueDate { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Paid { get; set; }
    public decimal Adjusted { get; set; }   // debit notes set off (SQLScripts/2400)
    public decimal Balance => NetAmount - Paid - Adjusted;
}

/// <summary>An open debit note (purchase return) of a supplier (SQLScripts/2400).</summary>
public class PhOpenDebitNote
{
    public int ReturnId { get; set; }
    public string ReturnNo { get; set; } = "";
    public DateTime ReturnDate { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Adjusted { get; set; }
    public decimal Available => NetAmount - Adjusted;
}

public class PhSupplierBalance
{
    public int SupplierId { get; set; }
    public string SupplierName { get; set; } = "";
    public decimal Purchases { get; set; }
    public decimal Returns { get; set; }
    public decimal Paid { get; set; }
    /// <summary>Purchases - returns - paid: positive = payable to the supplier; negative = debit balance (the supplier owes the branch).</summary>
    public decimal Balance => Purchases - Returns - Paid;
    public decimal Adjusted { get; set; }       // SQLScripts/2400: debit notes set off against bills
    public decimal UnadjustedDn { get; set; }   // open debit notes, to adjust at the next payment
    public decimal BillsDue { get; set; }       // open bills' balance (net of payments and adjustments)
    public decimal Overdue { get; set; }
    public int OpenBills { get; set; }
}

public class PhBranchHeader
{
    public string Name { get; set; } = "";
    public string? Address { get; set; }
    public string? Phone { get; set; }
    public string? Gstin { get; set; }
    public string? Licence20B { get; set; }
    public string? Licence21B { get; set; }
    public string? Pharmacist { get; set; }
    public string? LogoPath { get; set; }
}

/// <summary>What a purchase document page needs: the document, its lookups and which buttons the user may use.</summary>
/// <summary>A pharmacy store / godown of the branch (SQLScripts/2364).</summary>
public class PhStoreOption
{
    public int StoreId { get; set; }
    public string StoreCode { get; set; } = "";
    public string StoreName { get; set; } = "";
    public string StoreType { get; set; } = "";
    public bool CanReceive { get; set; }
    public bool CanSell { get; set; }
    public bool IsDefault { get; set; }
}

public class PhDocPage
{
    public string Kind { get; set; } = "";
    public string PageCode { get; set; } = "";
    public string Title { get; set; } = "";
    public string Icon { get; set; } = "";
    public string Description { get; set; } = "";
    public PhDoc Doc { get; set; } = new();
    public List<PhOption> Suppliers { get; set; } = [];
    public List<PhStoreOption> Stores { get; set; } = [];
    public List<PhOption> Reasons { get; set; } = [];
    public List<PhOption> OpenPos { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
    public PhSupplierInfo? Supplier { get; set; }
    public int MinShelfLifeDays { get; set; }
    public bool Gs1ScanEnabled { get; set; }
    public bool Editable => Doc.Status == "DRAFT";
    public bool Direct => Kind == "po" && Doc.IsDirect;
}

public class PhRateHistory
{
    public DateTime GrnDate { get; set; }
    public string? GrnNo { get; set; }
    public string SupplierName { get; set; } = "";
    public string BatchNo { get; set; } = "";
    public decimal Qty { get; set; }
    public decimal FreeQty { get; set; }
    public decimal Rate { get; set; }
    public decimal DiscPercent { get; set; }
    public decimal GstPercent { get; set; }
    public decimal Mrp { get; set; }
    public decimal NetRate => Math.Round(Rate * (1 - DiscPercent / 100) * Qty / Math.Max(1, Qty + FreeQty), 2);   // effective rate with free goods
}

public class PhRegisterRow
{
    public string DocType { get; set; } = "";      // Purchase | Debit note
    public int Id { get; set; }
    public string DocNo { get; set; } = "";
    public DateTime DocDate { get; set; }
    public string SupplierName { get; set; } = "";
    public string? Gstin { get; set; }
    public string? StateName { get; set; }          // SQLScripts/2399
    public string SupplyType { get; set; } = "";   // Intra-state | Inter-state
    public string? InvoiceNo { get; set; }          // a debit note: the supplier bill(s) of the returned batches
    public DateTime? InvoiceDate { get; set; }
    public string? RefGrnNo { get; set; }           // a debit note: the GRN(s) it returns against
    public int Lines { get; set; }
    public decimal Qty { get; set; }
    public decimal FreeQty { get; set; }
    public decimal Gross { get; set; }
    public decimal Discount { get; set; }
    public decimal Taxable { get; set; }
    public decimal Cgst { get; set; }
    public decimal Sgst { get; set; }
    public decimal Igst { get; set; }
    public decimal Gst { get; set; }
    public decimal Other { get; set; }
    public decimal RoundOff { get; set; }
    public decimal Net { get; set; }
}

public class PhGstSummaryRow
{
    public decimal GstPercent { get; set; }
    public decimal PurchaseTaxable { get; set; }
    public decimal ReturnTaxable { get; set; }
    public decimal Taxable { get; set; }
    public decimal Cgst { get; set; }
    public decimal Sgst { get; set; }
    public decimal Igst { get; set; }
    public decimal Gst { get; set; }
}

public class PhSupplierSummaryRow
{
    public string SupplierName { get; set; } = "";
    public string? Gstin { get; set; }
    public string? StateName { get; set; }
    public int Purchases { get; set; }
    public decimal PurchaseAmount { get; set; }
    public int Returns { get; set; }
    public decimal ReturnAmount { get; set; }
    public decimal Taxable { get; set; }
    public decimal Gst { get; set; }
    public decimal Net { get; set; }
}

public interface IPharmacyPurchaseService
{
    Task<List<PhRateHistory>> RateHistoryAsync(int companyId, int itemId);
    Task<string?> AttachAsync(int companyId, int branchId, int grnId, string path, string name);
    Task MarkEmailedAsync(int poId, string email);
    Task MarkIndentEmailedAsync(int indentId, string email);
    Task<(List<PhRegisterRow> Rows, List<PhGstSummaryRow> Gst, List<PhSupplierSummaryRow> Suppliers)> RegisterAsync(int companyId, int branchId, DateTime from, DateTime to, int? supplierId, string? docType = null, string? search = null);
    Task<List<PhOption>> OpenPosAsync(int companyId, int branchId, int supplierId);
    Task<PhBranchHeader> BranchHeaderAsync(int branchId);
    Task<List<PhTxnItem>> ItemSearchAsync(int companyId, int branchId, string q, int take = 15);
    Task<List<PhOption>> SuppliersAsync(int companyId);
    /// <summary>The branch's stores: purpose RECEIVE / SELL / ANY; the default for the purpose comes first.</summary>
    Task<List<PhStoreOption>> StoresAsync(int companyId, int branchId, string purpose);
    /// <summary>Read a supplier's bill (PDF / photo) on the server (SQLScripts/2367): the reader's result as JSON for the form.</summary>
    Task<System.Text.Json.JsonElement> ReadBillAsync(int companyId, int branchId, IFormFile file);
    /// <summary>Remember the bill names the user confirmed (BillText -> ItemId).</summary>
    Task LearnBillAsync(int companyId, int? supplierId, string pairsJson);
    Task<PhSupplierInfo?> SupplierInfoAsync(int companyId, int branchId, int supplierId);
    Task<List<PhOption>> ReasonsAsync(int companyId, string type);
    Task<int> MinShelfLifeGrnDaysAsync(int branchId);
    Task<bool> GrnNotRequiredAsync(int branchId);
    Task<bool> Gs1ScanEnabledAsync(int branchId);
    Task<Dictionary<string, int>> StatusCountsAsync(string kind, int companyId, int branchId);
    Task<List<PhDocListRow>> ListAsync(string kind, int companyId, int branchId, string? status, string? search, DateTime? from, DateTime? to);
    Task<PhDoc?> GetAsync(string kind, int companyId, int branchId, int id);

    Task<List<PhTxnItem>> ReorderSuggestAsync(int companyId, int branchId);
    Task<(PhReorderSettings Settings, List<PhReorderRow> Rows)> AutoReorderAsync(int companyId, int branchId, int? supplierId, int? categoryId, bool showAll);
    Task<(List<PhReorderCreated> Created, string? Error)> AutoReorderCreatePosAsync(int companyId, int branchId, List<PhReorderLine> lines, int userId);
    Task<PhSchemeFree> SchemeFreeAsync(int companyId, int branchId, int supplierId, int itemId, decimal qty);
    Task<(int Id, string? Error)> SaveIndentAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> IndentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhDocLine>> IndentLinesForPoAsync(int companyId, int branchId, int indentId);
    Task<(int Id, string? Error)> SavePoAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> PoActionAsync(int companyId, int branchId, int id, string action, int userId);

    Task<List<PhDocLine>> PoLinesForGrnAsync(int companyId, int branchId, int poId);
    Task<(int Id, List<string> Warnings, string? Error)> SaveGrnAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<string?> DeleteDraftAsync(string kind, int companyId, int branchId, int id);
    Task<List<string>> GrnWarningsAsync(int companyId, int branchId, int grnId);
    Task<(string? DocNo, string? Error)> PostGrnAsync(int companyId, int branchId, int id, bool acceptWarnings, int userId);

    Task<List<PhBatchPick>> BatchSearchAsync(int companyId, int branchId, string q, int? supplierId, int? storeId = null);
    Task<(int Id, string? Error)> SaveReturnAsync(int companyId, int branchId, PhDoc d, int userId);
    Task<(string? DocNo, string? Error)> PostReturnAsync(int companyId, int branchId, int id, int userId);

    Task<List<PhSupplierBalance>> SupplierBalancesAsync(int companyId, int branchId);
    Task<List<PhPayable>> PayablesAsync(int companyId, int branchId, int supplierId);
    Task<(int Id, string? Error)> SavePaymentAsync(int companyId, int branchId, int supplierId, DateTime date, string mode, string? reference, string? remarks, Dictionary<int, decimal> alloc, int userId, Dictionary<int, decimal>? adjust = null);
    Task<List<PhOpenDebitNote>> OpenDebitNotesAsync(int companyId, int branchId, int supplierId);
    Task<string?> CancelPaymentAsync(int companyId, int branchId, int id, int userId);
}

/// <summary>
/// Pharmacy > Purchase through EMR.Api (api/pharmacy/purchase, SQLScripts/2358). The checks, line amounts, warnings
/// and the "GRN not required" approval are worked out here as before; every read and save is an API call.
/// </summary>
public class PharmacyPurchaseService(PharmacyApiClient api) : IPharmacyPurchaseService
{
    private const string Base = "api/pharmacy/purchase";
    private static string Q(params (string, object?)[] a) => PharmacyApiClient.Q(a);
    // lines for OPENJSON: property names exactly as the procedure's WITH clause (PascalCase), not the API's camelCase
    private static string Json(object o) => System.Text.Json.JsonSerializer.Serialize(o);

    private sealed class PhResult { public int Id { get; set; } public string? DocNo { get; set; } public string? Error { get; set; } }
    private sealed class DocWire { public PhDoc? Header { get; set; } public List<PhDocLine> Lines { get; set; } = []; public List<PhTxnItem> Items { get; set; } = []; }
    private sealed record Settings(bool GrnNotRequired, int MinShelfLifeGrnDays, bool Gs1ScanEnabled = false);
    private sealed record StatusCount(string Status, int Cnt);
    private sealed record LastMrpRow(int ItemId, decimal? LastMrp);

    public static readonly Dictionary<string, (string Label, string Css)> StatusInfo = new()
    {
        ["DRAFT"] = ("Draft", "bg-secondary-subtle text-secondary-emphasis border border-secondary-subtle"),
        ["SUBMITTED"] = ("Submitted", "bg-info-subtle text-info-emphasis border border-info-subtle"),
        ["APPROVED"] = ("Approved", "bg-primary-subtle text-primary-emphasis border border-primary-subtle"),
        ["PARTIAL"] = ("Part received", "bg-warning-subtle text-warning-emphasis border border-warning-subtle"),
        ["ORDERED"] = ("Ordered", "bg-success-subtle text-success border border-success-subtle"),
        ["CLOSED"] = ("Closed", "bg-success-subtle text-success border border-success-subtle"),
        ["POSTED"] = ("Posted", "bg-success-subtle text-success border border-success-subtle"),
        ["REJECTED"] = ("Rejected", "bg-danger-subtle text-danger border border-danger-subtle"),
        ["CANCELLED"] = ("Cancelled", "bg-light text-secondary border")
    };

    private static decimal R2(decimal v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);

    public Task<List<PhRateHistory>> RateHistoryAsync(int companyId, int itemId) =>
        api.GetAsync<List<PhRateHistory>>($"{Base}/rate-history" + Q(("companyId", companyId), ("itemId", itemId)));

    public async Task<string?> AttachAsync(int companyId, int branchId, int grnId, string path, string name) =>
        (await api.PostAsync<PhResult>($"{Base}/grn/attach", new { companyId, branchId, grnId, path, name })).Error;

    public Task MarkEmailedAsync(int poId, string email) => api.PostAsync($"{Base}/po/emailed", new { poId, email });

    public Task MarkIndentEmailedAsync(int indentId, string email) => api.PostAsync($"{Base}/indent/emailed", new { indentId, email });

    public async Task<(List<PhRegisterRow> Rows, List<PhGstSummaryRow> Gst, List<PhSupplierSummaryRow> Suppliers)> RegisterAsync(int companyId, int branchId, DateTime from, DateTime to, int? supplierId, string? docType = null, string? search = null)
    {
        var sets = await api.GetAsync<List<List<System.Text.Json.JsonElement>>>($"{Base}/register" +
            Q(("companyId", companyId), ("branchId", branchId), ("from", from), ("to", to), ("supplierId", supplierId), ("docType", docType), ("search", search)));
        return (sets[0].Select(e => e.Deserialize<PhRegisterRow>(PharmacyApiClient.Json)!).ToList(),
                sets[1].Select(e => e.Deserialize<PhGstSummaryRow>(PharmacyApiClient.Json)!).ToList(),
                sets.Count > 2 ? sets[2].Select(e => e.Deserialize<PhSupplierSummaryRow>(PharmacyApiClient.Json)!).ToList() : []);
    }

    /// <summary>Indian-style amount in words: "Rupees One Lakh Twenty Three Thousand ... and Fifty Paise Only".</summary>
    public static string AmountInWords(decimal amount)
    {
        string[] ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
        string[] tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];
        string Two(long n) => n < 20 ? ones[n] : tens[n / 10] + (n % 10 > 0 ? " " + ones[n % 10] : "");
        string Three(long n) => (n >= 100 ? ones[n / 100] + " Hundred" + (n % 100 > 0 ? " " : "") : "") + (n % 100 > 0 ? Two(n % 100) : "");
        amount = Math.Abs(Math.Round(amount, 2));
        var rupees = (long)Math.Floor(amount); var paise = (long)Math.Round((amount - rupees) * 100);
        if (rupees == 0 && paise == 0) return "Rupees Zero Only";
        var parts = new List<string>();
        var crore = rupees / 10000000; rupees %= 10000000;
        var lakh = rupees / 100000; rupees %= 100000;
        var thousand = rupees / 1000; rupees %= 1000;
        if (crore > 0) parts.Add(Three(crore) + " Crore");
        if (lakh > 0) parts.Add(Two(lakh) + " Lakh");
        if (thousand > 0) parts.Add(Two(thousand) + " Thousand");
        if (rupees > 0) parts.Add(Three(rupees));
        var words = parts.Count > 0 ? "Rupees " + string.Join(" ", parts) : "";
        if (paise > 0) words += (words.Length > 0 ? " and " : "") + Two(paise) + " Paise";
        return words + " Only";
    }

    public Task<List<PhOption>> OpenPosAsync(int companyId, int branchId, int supplierId) =>
        api.GetAsync<List<PhOption>>($"{Base}/open-pos" + Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId)));

    public async Task<PhBranchHeader> BranchHeaderAsync(int branchId) =>
        (await api.GetAsync<List<PhBranchHeader>>($"{Base}/branch-header/{branchId}")).FirstOrDefault() ?? new PhBranchHeader { Name = "Pharmacy" };

    // ── lookups ──────────────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhTxnItem>> ItemSearchAsync(int companyId, int branchId, string q, int take = 15) =>
        api.GetAsync<List<PhTxnItem>>($"{Base}/item-search" + Q(("companyId", companyId), ("branchId", branchId), ("q", q), ("take", take)));

    public Task<List<PhOption>> SuppliersAsync(int companyId) => api.GetAsync<List<PhOption>>($"{Base}/suppliers" + Q(("companyId", companyId)));

    public Task<System.Text.Json.JsonElement> ReadBillAsync(int companyId, int branchId, IFormFile file) =>
        api.PostFileAsync<System.Text.Json.JsonElement>("api/pharmacy/bill/read", file, ("companyId", companyId.ToString()), ("branchId", branchId.ToString()));

    public Task LearnBillAsync(int companyId, int? supplierId, string pairsJson) =>
        api.PostAsync("api/pharmacy/bill/learn", new { companyId, supplierId, pairs = pairsJson });

    public Task<List<PhStoreOption>> StoresAsync(int companyId, int branchId, string purpose) =>
        api.GetAsync<List<PhStoreOption>>("api/pharmacy/inventory/stores" + Q(("companyId", companyId), ("branchId", branchId), ("purpose", purpose)));

    public Task<List<PhOption>> ReasonsAsync(int companyId, string type) =>
        api.GetAsync<List<PhOption>>($"{Base}/reasons" + Q(("companyId", companyId), ("type", type)));

    private async Task<Settings> SettingsAsync(int branchId) =>
        (await api.GetAsync<List<Settings>>($"{Base}/settings/{branchId}")).FirstOrDefault() ?? new Settings(false, 90);

    public async Task<bool> GrnNotRequiredAsync(int branchId) => (await SettingsAsync(branchId)).GrnNotRequired;

    public async Task<bool> Gs1ScanEnabledAsync(int branchId) => (await SettingsAsync(branchId)).Gs1ScanEnabled;

    public async Task<int> MinShelfLifeGrnDaysAsync(int branchId) => (await SettingsAsync(branchId)).MinShelfLifeGrnDays;

    public async Task<PhSupplierInfo?> SupplierInfoAsync(int companyId, int branchId, int supplierId)
    {
        var s = (await api.GetAsync<List<PhSupplierInfo>>($"{Base}/supplier-info" + Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId)))).FirstOrDefault();
        if (s?.DrugLicenceValidTo is { } v && v < DateTime.Today) s.Warning = $"Supplier's drug licence expired on {v:dd-MMM-yyyy}.";
        return s;
    }

    public async Task<Dictionary<string, int>> StatusCountsAsync(string kind, int companyId, int branchId) =>
        (await api.GetAsync<List<StatusCount>>($"{Base}/status-counts/{kind}" + Q(("companyId", companyId), ("branchId", branchId))))
            .ToDictionary(x => x.Status, x => x.Cnt);

    public Task<List<PhDocListRow>> ListAsync(string kind, int companyId, int branchId, string? status, string? search, DateTime? from, DateTime? to) =>
        api.GetAsync<List<PhDocListRow>>($"{Base}/list/{kind}" + Q(("companyId", companyId), ("branchId", branchId), ("status", status),
            ("search", string.IsNullOrWhiteSpace(search) ? null : search.Trim()), ("from", from), ("to", to)));

    public async Task<PhDoc?> GetAsync(string kind, int companyId, int branchId, int id)
    {
        var w = await api.GetAsync<DocWire>($"{Base}/doc/{kind}/{id}" + Q(("companyId", companyId), ("branchId", branchId)));
        if (w.Header == null) return null;
        w.Header.Lines = w.Lines;
        FillItemInfo(w.Lines, w.Items);
        return w.Header;
    }

    private static void FillItemInfo(List<PhDocLine> lines, List<PhTxnItem> items)
    {
        var info = items.ToDictionary(i => i.ItemId);
        foreach (var l in lines)
            if (info.TryGetValue(l.ItemId, out var i))
            {
                l.ItemName = i.ItemName; l.ItemCode = i.ItemCode; l.FormShort = i.FormShort; l.PurchaseUom = i.PurchaseUom; l.SaleUom = i.SaleUom; l.ConversionQty = i.ConversionQty;
                if (l.BatchId == null) l.Stock = i.Stock;
            }
    }

    // ── purchase indent ──────────────────────────────────────────────────────────────────────────────────
    public async Task<(PhReorderSettings Settings, List<PhReorderRow> Rows)> AutoReorderAsync(int companyId, int branchId, int? supplierId, int? categoryId, bool showAll)
    {
        var sets = await api.GetAsync<List<List<System.Text.Json.JsonElement>>>($"{Base}/auto-reorder" +
            Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId), ("categoryId", categoryId), ("showAll", showAll)));
        var settings = sets.Count > 0 && sets[0].Count > 0 ? sets[0][0].Deserialize<PhReorderSettings>(PharmacyApiClient.Json)! : new PhReorderSettings();
        var rows = sets.Count > 1 ? sets[1].Select(e => e.Deserialize<PhReorderRow>(PharmacyApiClient.Json)!).ToList() : [];
        return (settings, rows);
    }

    public async Task<(List<PhReorderCreated> Created, string? Error)> AutoReorderCreatePosAsync(int companyId, int branchId, List<PhReorderLine> lines, int userId)
    {
        lines = lines.Where(l => l.ItemId > 0).ToList();
        if (lines.Count == 0) return ([], "Tick at least one item.");
        if (lines.Count > 500) return ([], "Up to 500 items at a time.");
        var rows = await api.PostAsync<List<PhReorderCreated>>($"{Base}/auto-reorder/create-pos", new { companyId, branchId, userId, Lines = Json(lines) });
        var err = rows.FirstOrDefault(r => !string.IsNullOrEmpty(r.Error))?.Error;
        return err != null ? ([], err) : (rows, null);
    }

    public async Task<PhSchemeFree> SchemeFreeAsync(int companyId, int branchId, int supplierId, int itemId, decimal qty) =>
        (await api.GetAsync<List<PhSchemeFree>>($"{Base}/scheme-free" + Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId), ("itemId", itemId), ("qty", qty))))
            .FirstOrDefault() ?? new PhSchemeFree();

    public Task<List<PhTxnItem>> ReorderSuggestAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhTxnItem>>($"{Base}/reorder" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<(int Id, string? Error)> SaveIndentAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (lines.Count == 0) return (0, "Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every item needs a quantity above zero.");
        if (lines.GroupBy(l => l.ItemId).Any(g => g.Count() > 1)) return (0, "An item is listed twice; keep one line per item.");
        if (d.SupplierId is null or 0) return (0, "Pick the supplier the indent is for.");   // SQLScripts/2413
        var r = await api.PostAsync<PhResult>($"{Base}/indent/save", new
        {
            d.Id, companyId, branchId, userId, d.DocDate, d.Priority, d.Remarks, d.SupplierId,
            Lines = Json(lines.Select(l => new { l.ItemId, l.Qty, l.Remarks }))
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> IndentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId) =>
        (await api.PostAsync<PhResult>($"{Base}/indent/action", new { id, companyId, branchId, userId, action, remarks })).Error;

    // ── purchase order ───────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhDocLine>> IndentLinesForPoAsync(int companyId, int branchId, int indentId)
    {
        var w = await api.GetAsync<DocWire>($"{Base}/po/indent-lines" + Q(("companyId", companyId), ("branchId", branchId), ("indentId", indentId)));
        FillItemInfo(w.Lines, w.Items);
        return w.Lines;
    }

    private static void Price(PhDocLine l)
    {
        l.TaxableAmount = R2(l.Qty * l.Rate * (1 - l.DiscPercent / 100));
        l.GstAmount = R2(l.TaxableAmount * l.GstPercent / 100);
    }

    private static string? CheckPricedLines(List<PhDocLine> lines)
    {
        if (lines.Count == 0) return "Add at least one item.";
        if (lines.Any(l => l.Qty <= 0)) return "Every item needs a quantity above zero.";
        if (lines.Any(l => l.FreeQty < 0 || l.Rate < 0)) return "Free quantity and rate cannot be negative.";
        if (lines.Any(l => l.DiscPercent is < 0 or > 100)) return "Discount % must be between 0 and 100.";
        if (lines.Any(l => l.GstPercent is not (0 or 5 or 12 or 18 or 28))) return "GST % must be 0, 5, 12, 18 or 28.";
        return null;
    }

    public async Task<(int Id, string? Error)> SavePoAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (d.SupplierId is null or 0) return (0, "Pick the supplier.");
        if (CheckPricedLines(lines) is { } err) return (0, err);
        if (lines.Any(l => l.Rate <= 0)) return (0, "Every item needs a rate.");
        if (d.ExpectedDate != null && d.ExpectedDate < d.DocDate) return (0, "Expected delivery is before the order date.");
        // a draft keeps the mode it was started in (never taken from the page)
        d.IsDirect = (await api.GetAsync<List<PhDoc>>($"{Base}/po/mode" + Q(("id", d.Id), ("companyId", companyId), ("branchId", branchId)))).FirstOrDefault()?.IsDirect ?? false;
        if (d.IsDirect)
        {
            d.InvoiceNo = d.InvoiceNo?.Trim();
            if (string.IsNullOrWhiteSpace(d.InvoiceNo)) return (0, "Enter the supplier's bill number (GRN is not required, so the order takes the bill).");
            if (d.InvoiceDate == null) return (0, "Enter the supplier's bill date.");
            if (d.InvoiceDate > DateTime.Today) return (0, "Bill date cannot be in the future.");
            if (d.OtherCharges < 0) return (0, "Other charges cannot be negative.");
            if (CheckBatchLines(lines) is { } berr) return (0, berr);
        }
        else { d.InvoiceNo = null; d.InvoiceDate = null; d.InvoiceAmount = 0; d.OtherCharges = 0; lines.ForEach(l => { l.BatchNo = null; l.ExpiryDate = null; l.Mrp = 0; }); }
        lines.ForEach(Price);
        var taxable = lines.Sum(l => l.TaxableAmount); var gst = lines.Sum(l => l.GstAmount);
        var net = d.IsDirect ? Math.Round(taxable + gst + d.OtherCharges, 0, MidpointRounding.AwayFromZero) : R2(taxable + gst);
        var r = await api.PostAsync<PhResult>($"{Base}/po/save", new
        {
            d.Id, companyId, branchId, userId, d.DocDate, SupplierId = d.SupplierId!.Value, IndentId = d.RefId, d.ExpectedDate, d.IsInterState, d.Terms, d.Remarks,
            Taxable = taxable, Gst = gst, Net = net, d.IsDirect, d.InvoiceNo, d.InvoiceDate, InvoiceAmount = d.IsDirect ? d.InvoiceAmount : (decimal?)null, d.OtherCharges,
            Lines = Json(lines.Select(l => new
            {
                l.ItemId, l.Qty, l.FreeQty, l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount, l.BatchNo,
                ExpiryDate = l.ExpiryDate?.ToString("yyyy-MM-dd"), Mrp = d.IsDirect ? l.Mrp : (decimal?)null
            }))
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> PoActionAsync(int companyId, int branchId, int id, string action, int userId)
    {
        if (action == "approve" && await GetAsync("po", companyId, branchId, id) is { IsDirect: true, Status: "DRAFT" } direct)
            return await ApproveDirectAsync(companyId, branchId, direct, userId);
        return await PoActionCoreAsync(companyId, branchId, id, action, userId);
    }

    /// <summary>GRN Not Required: approve the order, then create and post its GRN (stock in). If the GRN cannot be posted the order goes back to draft.</summary>
    private async Task<string?> ApproveDirectAsync(int companyId, int branchId, PhDoc po, int userId)
    {
        if (Math.Abs(po.InvoiceAmount - po.NetAmount) > 1)
            return $"Supplier bill amount ₹{po.InvoiceAmount:0.00} and order total ₹{po.NetAmount:0.00} differ. Correct the lines or the bill amount before approving.";
        if (await PoActionCoreAsync(companyId, branchId, po.Id, "approve", userId) is { } err) return err;
        var grn = new PhDoc
        {
            DocDate = po.DocDate > DateTime.Today ? DateTime.Today : po.DocDate, SupplierId = po.SupplierId, RefId = po.Id, InvoiceNo = po.InvoiceNo, InvoiceDate = po.InvoiceDate,
            InvoiceAmount = po.InvoiceAmount, OtherCharges = po.OtherCharges, IsInterState = po.IsInterState, Remarks = "Posted on approval of the purchase order (GRN not required).",
            Lines = po.Lines.Select(l => new PhDocLine { PoDtlId = l.LineId, ItemId = l.ItemId, BatchNo = l.BatchNo, ExpiryDate = l.ExpiryDate, Mrp = l.Mrp, Qty = l.Qty, FreeQty = l.FreeQty,
                                                         Rate = l.Rate, DiscPercent = l.DiscPercent, GstPercent = l.GstPercent }).ToList()
        };
        var (grnId, _, saveErr) = await SaveGrnAsync(companyId, branchId, grn, userId);
        string? postErr = saveErr;
        if (saveErr == null) (_, postErr) = await PostGrnAsync(companyId, branchId, grnId, true, userId);
        if (postErr == null) return null;
        await api.PostAsync($"{Base}/po/undo-direct", new { poId = po.Id, grnId });   // back to draft (the PO number already given is not reused)
        return "Stock could not be posted, so the order is back to draft: " + postErr;
    }

    private async Task<string?> PoActionCoreAsync(int companyId, int branchId, int id, string action, int userId) =>
        (await api.PostAsync<PhResult>($"{Base}/po/action", new { id, companyId, branchId, userId, action, remarks = (string?)null })).Error;

    // ── GRN ──────────────────────────────────────────────────────────────────────────────────────────────
    public async Task<List<PhDocLine>> PoLinesForGrnAsync(int companyId, int branchId, int poId)
    {
        var w = await api.GetAsync<DocWire>($"{Base}/grn/po-lines" + Q(("companyId", companyId), ("branchId", branchId), ("poId", poId)));
        FillItemInfo(w.Lines, w.Items);
        return w.Lines;
    }

    public async Task<(int Id, List<string> Warnings, string? Error)> SaveGrnAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var warn = new List<string>();
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        d.InvoiceNo = d.InvoiceNo?.Trim();
        if (d.SupplierId is null or 0) return (0, warn, "Pick the supplier.");
        if (string.IsNullOrWhiteSpace(d.InvoiceNo)) return (0, warn, "Enter the supplier's invoice number.");
        if (d.InvoiceDate == null) return (0, warn, "Enter the supplier's invoice date.");
        if (d.InvoiceDate > d.DocDate) return (0, warn, "Invoice date is after the GRN date.");
        if (d.DocDate > DateTime.Today) return (0, warn, "GRN date cannot be in the future.");
        if (d.OtherCharges < 0) return (0, warn, "Other charges cannot be negative.");
        if (CheckPricedLines(lines) is { } err) return (0, warn, err);
        if (CheckBatchLines(lines) is { } berr) return (0, warn, berr);
        lines.ForEach(Price);
        var r = await api.PostAsync<PhResult>($"{Base}/grn/save", new
        {
            d.Id, companyId, branchId, userId, d.DocDate, SupplierId = d.SupplierId!.Value, PoId = d.RefId, d.InvoiceNo, InvoiceDate = d.InvoiceDate!.Value, d.InvoiceAmount,
            d.IsInterState, d.OtherCharges, d.Remarks, d.StoreId,
            Lines = Json(lines.Select(l => new
            {
                l.PoDtlId, l.ItemId, l.BatchNo, MfgDate = l.MfgDate?.ToString("yyyy-MM-dd"), ExpiryDate = l.ExpiryDate?.ToString("yyyy-MM-dd"), l.Mrp, l.Qty, l.FreeQty,
                l.Rate, l.DiscPercent, l.GstPercent, l.TaxableAmount, l.GstAmount
            }))
        });
        if (r.Error != null) return (0, warn, r.Error);
        warn.AddRange(await GrnWarningsAsync(companyId, branchId, r.Id));
        return (r.Id, warn, null);
    }

    /// <summary>Batch, expiry and MRP rules for stock coming in (GRN, or a purchase order when GRN is not required).</summary>
    private static string? CheckBatchLines(List<PhDocLine> lines)
    {
        foreach (var l in lines)
        {
            l.BatchNo = l.BatchNo?.Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(l.BatchNo) || l.BatchNo.Length > 30) return "Every item needs a batch number (up to 30 characters).";
            if (l.ExpiryDate == null) return $"Enter the expiry of batch {l.BatchNo}.";
            l.ExpiryDate = new DateTime(l.ExpiryDate.Value.Year, l.ExpiryDate.Value.Month, DateTime.DaysInMonth(l.ExpiryDate.Value.Year, l.ExpiryDate.Value.Month));
            if (l.ExpiryDate <= DateTime.Today) return $"Batch {l.BatchNo} has already expired.";
            if (l.MfgDate != null && l.MfgDate >= l.ExpiryDate) return $"Batch {l.BatchNo}: manufacturing date is after expiry.";
            if (l.Mrp <= 0) return $"Enter the MRP of batch {l.BatchNo}.";
            var costWithGst = l.Rate * (1 - l.DiscPercent / 100) * (1 + l.GstPercent / 100);
            if (costWithGst > l.Mrp) return $"Batch {l.BatchNo}: purchase cost with GST (₹{costWithGst:0.00}) is above the MRP (₹{l.Mrp:0.00}).";
        }
        if (lines.GroupBy(l => (l.ItemId, l.BatchNo, l.Mrp)).Any(g => g.Count() > 1)) return "The same item, batch and MRP is entered twice; put it on one line.";
        return null;
    }

    public async Task<List<string>> GrnWarningsAsync(int companyId, int branchId, int grnId)
    {
        var w = new List<string>();
        var g = await GetAsync("grn", companyId, branchId, grnId);
        if (g == null) return w;
        var days = await MinShelfLifeGrnDaysAsync(branchId);
        foreach (var l in g.Lines.Where(l => l.ExpiryDate < DateTime.Today.AddDays(days)))
            w.Add($"{l.ItemName} batch {l.BatchNo} expires {l.ExpiryDate:MMM-yyyy}: less than {days} days of shelf life.");
        var last = (await api.GetAsync<List<LastMrpRow>>($"{Base}/grn/last-mrps" + Q(("companyId", companyId), ("branchId", branchId), ("grnId", grnId))))
            .ToDictionary(x => x.ItemId, x => x.LastMrp);
        foreach (var l in g.Lines)
            if (last.GetValueOrDefault(l.ItemId) is { } lm && lm != l.Mrp) w.Add($"{l.ItemName}: MRP ₹{l.Mrp:0.00} differs from the last purchase (₹{lm:0.00}).");
        if (Math.Abs(g.InvoiceAmount - g.NetAmount) > 1)
            w.Add($"Supplier bill amount ₹{g.InvoiceAmount:0.00} does not match the GRN total ₹{g.NetAmount:0.00} (difference ₹{g.InvoiceAmount - g.NetAmount:0.00}).");
        if (await SupplierInfoAsync(companyId, branchId, g.SupplierId!.Value) is { Warning: { } sw }) w.Add(sw);
        return w;
    }

    public async Task<string?> DeleteDraftAsync(string kind, int companyId, int branchId, int id)
    {
        if (kind is not ("grn" or "return")) throw new ArgumentException(kind);
        return (await api.PostAsync<PhResult>($"{Base}/delete-draft/{kind}", new { companyId, branchId, id, userId = 0 })).Error;
    }

    public async Task<(string? DocNo, string? Error)> PostGrnAsync(int companyId, int branchId, int id, bool acceptWarnings, int userId)
    {
        var g = await GetAsync("grn", companyId, branchId, id);
        if (g == null) return (null, "GRN not found.");
        if (Math.Abs(g.InvoiceAmount - g.NetAmount) > 1) return (null, $"Supplier bill amount ₹{g.InvoiceAmount:0.00} and GRN total ₹{g.NetAmount:0.00} differ. Correct the lines or the bill amount before posting.");
        var warns = await GrnWarningsAsync(companyId, branchId, id);
        if (warns.Count > 0 && !acceptWarnings) return (null, "Tick 'I have checked the warnings' to post: " + string.Join(" ", warns));
        var r = await api.PostAsync<PhResult>($"{Base}/post/grn", new { companyId, branchId, id, userId });
        return (r.DocNo, r.Error);
    }

    // ── purchase return ──────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhBatchPick>> BatchSearchAsync(int companyId, int branchId, string q, int? supplierId, int? storeId = null) =>
        api.GetAsync<List<PhBatchPick>>($"{Base}/return/batches" + Q(("companyId", companyId), ("branchId", branchId), ("q", q), ("supplierId", supplierId), ("storeId", storeId)));

    public async Task<(int Id, string? Error)> SaveReturnAsync(int companyId, int branchId, PhDoc d, int userId)
    {
        var lines = d.Lines.Where(l => l.BatchId > 0).ToList();
        if (d.SupplierId is null or 0) return (0, "Pick the supplier.");
        if (d.ReasonId is null or 0) return (0, "Pick the reason for the return.");
        if (lines.Count == 0) return (0, "Add at least one batch.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every batch needs a quantity above zero.");
        if (lines.GroupBy(l => l.BatchId).Any(g => g.Count() > 1)) return (0, "A batch is listed twice.");
        // rate and GST always from the batch, quantity checked against stock now (and again when posted) - in the procedure
        var r = await api.PostAsync<PhResult>($"{Base}/return/save", new
        {
            d.Id, companyId, branchId, userId, d.DocDate, SupplierId = d.SupplierId!.Value, ReasonId = d.ReasonId!.Value, d.IsInterState, d.Remarks, d.StoreId,
            Lines = Json(lines.Select(l => new { l.BatchId, l.Qty }))
        });
        return (r.Id, r.Error);
    }

    public async Task<(string? DocNo, string? Error)> PostReturnAsync(int companyId, int branchId, int id, int userId)
    {
        var r = await api.PostAsync<PhResult>($"{Base}/post/return", new { companyId, branchId, id, userId });
        return (r.DocNo, r.Error);
    }

    // ── supplier payments ────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhSupplierBalance>> SupplierBalancesAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhSupplierBalance>>($"{Base}/payments/balances" + Q(("companyId", companyId), ("branchId", branchId)));

    public Task<List<PhPayable>> PayablesAsync(int companyId, int branchId, int supplierId) =>
        api.GetAsync<List<PhPayable>>($"{Base}/payments/payables" + Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId)));

    public Task<List<PhOpenDebitNote>> OpenDebitNotesAsync(int companyId, int branchId, int supplierId) =>
        api.GetAsync<List<PhOpenDebitNote>>($"{Base}/payments/debitnotes" + Q(("companyId", companyId), ("branchId", branchId), ("supplierId", supplierId)));

    public async Task<(int Id, string? Error)> SavePaymentAsync(int companyId, int branchId, int supplierId, DateTime date, string mode, string? reference, string? remarks, Dictionary<int, decimal> alloc, int userId, Dictionary<int, decimal>? adjust = null)
    {
        alloc = alloc.Where(a => a.Value > 0).ToDictionary(a => a.Key, a => R2(a.Value));
        adjust = (adjust ?? []).Where(a => a.Value > 0).ToDictionary(a => a.Key, a => R2(a.Value));
        if (alloc.Count == 0 && adjust.Count == 0) return (0, "Enter the amount paid or the debit note adjusted against at least one bill.");
        var cashPaid = alloc.Count > 0;   // SQLScripts/2400: adjustment only = no cash, no mode / reference needed
        if (cashPaid && mode is not ("CASH" or "CHEQUE" or "NEFT" or "UPI" or "CARD")) return (0, "Pick the payment mode.");
        if (cashPaid && mode != "CASH" && string.IsNullOrWhiteSpace(reference)) return (0, "Enter the cheque / transaction reference.");
        if (date > DateTime.Today) return (0, "Payment date cannot be in the future.");
        var r = await api.PostAsync<PhResult>($"{Base}/payments/save", new
        {
            companyId, branchId, userId, supplierId, date, mode, reference = reference?.Trim(), remarks,
            Alloc = Json(alloc.Select(a => new { GrnId = a.Key, Amount = a.Value })),
            Adjust = adjust.Count > 0 ? Json(adjust.Select(a => new { GrnId = a.Key, Amount = a.Value })) : null
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> CancelPaymentAsync(int companyId, int branchId, int id, int userId) =>
        (await api.PostAsync<PhResult>($"{Base}/payments/cancel", new { companyId, branchId, id, userId })).Error;
}
