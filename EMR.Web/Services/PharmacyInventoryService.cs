using System.Text.Json;
using EMR.Web.ApiClients;

namespace EMR.Web.Services;

// Pharmacy > Inventory (SQLScripts/2349): stock enquiry, branch indent & transfer, stock adjustment, expiry / damage write-off,
// physical stock verification, batch correction and the dashboard. Stock moves only through usp_PhStock_Move; approvals are
// maker-checker (Approval Matrix module, else the page's APPROVE control; never the maker); books by usp_Ph_PostInventoryLedger.

public class PhStockRow
{
    public int BatchId { get; set; }
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string? CategoryName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string? RackNo { get; set; }
    public string BatchNo { get; set; } = "";
    public DateTime ExpiryDate { get; set; }
    public decimal Mrp { get; set; }               // per pack
    public decimal LandedCost { get; set; }        // per sale unit
    public decimal GstPercent { get; set; }
    public decimal Stock { get; set; }             // sale units
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool IsBlocked { get; set; }
    public string? SupplierName { get; set; }
    public decimal CostValue => Math.Round(Stock * LandedCost, 2);
    public decimal MrpValue => ConversionQty == 0 ? 0 : Math.Round(Stock * Mrp / ConversionQty, 2);
    public int DaysToExpiry => (ExpiryDate - DateTime.Today).Days;
}

public class PhLedgerRow
{
    public DateTime TxnDate { get; set; }
    public string DocType { get; set; } = "";
    public string? DocNo { get; set; }
    public string BatchNo { get; set; } = "";
    public decimal QtyIn { get; set; }
    public decimal QtyOut { get; set; }
    public decimal BalanceAfter { get; set; }
    public decimal UnitCost { get; set; }
    public string? UserName { get; set; }
}

public class PhInvDocRow
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; }
    public string Status { get; set; } = "";
    public string? Party { get; set; }             // transfer: the other branch; adjustment: reason
    public string? Ref { get; set; }
    public int Lines { get; set; }
    public decimal Value { get; set; }
    public string? CreatedByName { get; set; }
    public int CreatedBy { get; set; }
    public string? Direction { get; set; }         // transfer: IN / OUT
}

/// <summary>A store issue in the list (Pharmacy > Inventory > Store Issue).</summary>
public class PhIssueRow
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; }
    public string Status { get; set; } = "";
    public string FromStore { get; set; } = "";
    public string ToStore { get; set; } = "";
    public int Lines { get; set; }
    public decimal CostValue { get; set; }
    public decimal VarianceValue { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime? ReceiveDate { get; set; }
}

/// <summary>A store issue: godown -> counter within the branch (SQLScripts/2364).</summary>
public class PhIssueDoc
{
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; } = DateTime.Today;
    public string Status { get; set; } = "DRAFT";
    public int FromStoreId { get; set; }
    public int ToStoreId { get; set; }
    public string? FromStore { get; set; }
    public string? ToStore { get; set; }
    public string? Remarks { get; set; }
    public string? IssueRemarks { get; set; }
    public string? ReceiveRemarks { get; set; }
    public decimal CostValue { get; set; }
    public decimal VarianceValue { get; set; }
    public DateTime? IssueDate { get; set; }
    public DateTime? ReceiveDate { get; set; }
    public int CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? CreatedByName { get; set; }
    public string? IssuedByName { get; set; }
    public string? ReceivedByName { get; set; }
    public List<PhIssueLine> Lines { get; set; } = [];
}

public class PhIssueLine
{
    public int LineId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? ItemCode { get; set; }
    public string? FormShort { get; set; }
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; } = 1;
    public decimal RequestQty { get; set; }        // > 0: request line; 0: an issued batch
    public int? BatchId { get; set; }
    public string? BatchNo { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public decimal? IssueQty { get; set; }
    public decimal? ReceivedQty { get; set; }
    public decimal? UnitCost { get; set; }
    public string? Remarks { get; set; }
    public string? VarianceReason { get; set; }
    public decimal FromStock { get; set; }
    public decimal ToStock { get; set; }
}

public class PhInvLine
{
    public int LineId { get; set; }
    public int ItemId { get; set; }
    public string ItemName { get; set; } = "";
    public string? ItemCode { get; set; }
    public string? FormShort { get; set; }
    public string SaleUom { get; set; } = "";
    public string PurchaseUom { get; set; } = "";
    public int ConversionQty { get; set; } = 1;
    public int? BatchId { get; set; }
    public string? BatchNo { get; set; }
    public DateTime? ExpiryDate { get; set; }
    public decimal Mrp { get; set; }
    public decimal Qty { get; set; }               // adjustment: change (+/-); transfer: request
    public decimal DispatchQty { get; set; }
    public decimal? ReceivedQty { get; set; }
    public decimal UnitCost { get; set; }
    public decimal Stock { get; set; }             // now, at the branch that acts
    public string? RackNo { get; set; }
    public string? Remarks { get; set; }
    public decimal SystemQty { get; set; }         // physical count snapshot
    public decimal? CountedQty { get; set; }
    public decimal? FirstCountQty { get; set; }    // SQLScripts/2405: kept when a big difference is sent for recount
    public bool RecountRequired { get; set; }
    public DateTime? RecountedDate { get; set; }
    public string? RecountedByName { get; set; }
}

/// <summary>A rack of the cycle count plan (SQLScripts/2405).</summary>
public class PhCycleRack
{
    public string RackNo { get; set; } = "";
    public int Items { get; set; }
    public int Batches { get; set; }
    public decimal StockValue { get; set; }
    public DateTime? LastCounted { get; set; }
    public string? OpenCount { get; set; }
    public int? DaysSince { get; set; }
    public int EveryDays { get; set; }
    public bool IsDue { get; set; }
}

public class PhInvDoc
{
    public int Id { get; set; }
    public int? StoreId { get; set; }             // adjustment / write-off / count: the store (SQLScripts/2364)
    public string? StoreName { get; set; }
    public int? FromStoreId { get; set; }         // transfer: store sent from / received into
    public int? ToStoreId { get; set; }
    public string? FromStore { get; set; }
    public string? ToStore { get; set; }
    public string Kind { get; set; } = "";
    public string? DocNo { get; set; }
    public DateTime DocDate { get; set; } = DateTime.Today;
    public string Status { get; set; } = "DRAFT";
    public int? ReasonId { get; set; }
    public string? ReasonName { get; set; }
    public string? Remarks { get; set; }
    public string? ActionRemarks { get; set; }
    public string? DisposalMethod { get; set; }
    public string? DisposalAgency { get; set; }
    public DateTime? DisposalDate { get; set; }
    public string? Witness1 { get; set; }
    public string? Witness2 { get; set; }
    public string? CertificateNo { get; set; }
    public decimal PlusValue { get; set; }
    public decimal MinusValue { get; set; }
    // transfer
    public int FromBranchId { get; set; }
    public int ToBranchId { get; set; }
    public string? FromBranch { get; set; }
    public string? ToBranch { get; set; }
    public string? TransferNo { get; set; }
    public DateTime? DispatchDate { get; set; }
    public DateTime? ReceiveDate { get; set; }
    public string? Priority { get; set; }
    public bool IsOtherGstin { get; set; }
    public string? DispatchRemarks { get; set; }
    public string? ReceiveRemarks { get; set; }
    public decimal CostValue { get; set; }
    public decimal VarianceValue { get; set; }
    // physical count
    public string? Scope { get; set; }
    public DateTime? FrozenAt { get; set; }
    public bool BlindCount { get; set; }           // SQLScripts/2405: Hospital Settings > MED
    public decimal RecountPercent { get; set; }
    public int? AdjustmentId { get; set; }
    public int CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public List<PhInvLine> Lines { get; set; } = [];
}

public class PhBatchCorrectionRow
{
    public int CorrectionId { get; set; }
    public string DocNo { get; set; } = "";
    public DateTime CreatedDate { get; set; }
    public string ItemName { get; set; } = "";
    public string OldBatchNo { get; set; } = ""; public string NewBatchNo { get; set; } = "";
    public DateTime OldExpiry { get; set; } public DateTime NewExpiry { get; set; }
    public decimal OldMrp { get; set; } public decimal NewMrp { get; set; }
    public string Reason { get; set; } = "";
    public string Status { get; set; } = "";
    public string? ActionRemarks { get; set; }
    public int CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public string? ApprovedByName { get; set; }
}

public class PhDashboard
{
    public decimal SalesToday { get; set; } public int BillsToday { get; set; } public decimal ReturnsToday { get; set; }
    public decimal CashToday { get; set; } public decimal NonCashToday { get; set; } public decimal CreditToday { get; set; }
    public decimal SalesMonth { get; set; } public decimal PurchasesToday { get; set; } public decimal PurchasesMonth { get; set; }
    public decimal StockValue { get; set; } public decimal StockMrpValue { get; set; } public int ItemsInStock { get; set; }
    public int Expired { get; set; } public decimal ExpiredValue { get; set; }
    public int Exp30 { get; set; } public decimal Exp30Value { get; set; } public int Exp60 { get; set; } public decimal Exp60Value { get; set; } public int Exp90 { get; set; } public decimal Exp90Value { get; set; }
    public int BelowReorder { get; set; } public int OutOfStock { get; set; }
    public decimal CreditDue { get; set; } public decimal SupplierDue { get; set; }
    public int PendIndents { get; set; } public int PendPos { get; set; } public int DraftGrns { get; set; } public int HeldBills { get; set; }
    public int ToDispatch { get; set; } public int ToReceive { get; set; } public int PendAdjust { get; set; } public int PendWriteOff { get; set; }
    public int PendCounts { get; set; } public int PendCorrections { get; set; }
    public List<(string ItemName, decimal Qty, decimal Value)> TopItems { get; set; } = [];
    public List<(DateTime Day, decimal Value)> Last7 { get; set; } = [];
    public List<PhStockRow> NearExpiry { get; set; } = [];
    public List<(string ItemName, decimal Stock, decimal Reorder, string Uom)> Reorder { get; set; } = [];
    // SQLScripts/2366
    public decimal SalesYesterday { get; set; } public int BillsMonth { get; set; } public decimal CostMonth { get; set; } public decimal ReturnsMonth { get; set; }
    public int DraftIndents { get; set; } public int IssuesToIssue { get; set; } public int IssuesToReceive { get; set; } public int Stores { get; set; }
    public List<PhPendingRequest> Pending { get; set; } = [];
    public List<PhStoreStockRow> StoreStock { get; set; } = [];
    public List<(string Mode, decimal Amount)> ModesToday { get; set; } = [];
    public List<(DateTime Day, decimal Sales, decimal Purchases)> Last14 { get; set; } = [];
}

/// <summary>A request waiting at this branch (dashboard reminder): purchase indent, branch indent / transfer or store request.</summary>
public class PhPendingRequest
{
    public string Kind { get; set; } = "";     // PURCHASE | BRANCH_OUT | BRANCH_IN | STORE_ISSUE | STORE_RECEIVE
    public int Id { get; set; }
    public string? DocNo { get; set; }
    public DateTime Since { get; set; }
    public string? Priority { get; set; }
    public string Title { get; set; } = "";
    public int Items { get; set; }
    public string? Party { get; set; }
}

public class PhStoreStockRow
{
    public string StoreName { get; set; } = "";
    public string StoreType { get; set; } = "";
    public int Items { get; set; }
    public decimal Value { get; set; }
}

public interface IPharmacyInventoryService
{
    Task<List<PhStockRow>> StockAsync(int companyId, int branchId, string? search, int? categoryId, string filter, int? storeId = null);
    Task<List<PhLedgerRow>> LedgerAsync(int companyId, int branchId, int itemId, int? batchId);
    Task<List<PhStockRow>> BatchSearchAsync(int companyId, int branchId, string q, bool expiredOnly = false, int? storeId = null);
    Task<List<PhOption>> OtherBranchesAsync(int companyId, int branchId);

    Task<List<PhInvDocRow>> TransfersAsync(int companyId, int branchId, string dir, string? status);
    Task<PhInvDoc?> GetTransferAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> SaveTransferRequestAsync(int companyId, int branchId, PhInvDoc d, bool submit, int userId);
    Task<string?> DispatchAsync(int companyId, int branchId, int id, List<PhInvLine> lines, string? remarks, int userId, int? storeId = null);
    Task<string?> ReceiveAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId, int? storeId = null);
    Task<string?> CancelTransferAsync(int companyId, int branchId, int id, int userId);

    Task<List<PhInvDocRow>> AdjustmentsAsync(int companyId, int branchId, string kind, string? status);
    Task<PhInvDoc?> GetAdjustmentAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> SaveAdjustmentAsync(int companyId, int branchId, PhInvDoc d, int userId);
    Task<string?> AdjustmentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhInvDocRow>> CountsAsync(int companyId, int branchId);
    Task<PhInvDoc?> GetCountAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> CreateCountAsync(int companyId, int branchId, string? rackPrefix, int? categoryId, bool includeZero, string? remarks, int userId, int? storeId = null);

    // stores and store issue (godown -> counter, SQLScripts/2364)
    Task<List<PhStoreOption>> StoresAsync(int companyId, int branchId, string purpose = "ANY");
    Task<List<PhPosBatch>> StoreBatchesAsync(int companyId, int branchId, int storeId, int itemId);
    Task<List<PhIssueRow>> IssuesAsync(int companyId, int branchId, string? status);
    Task<PhIssueDoc?> GetIssueAsync(int companyId, int branchId, int id);
    Task<(int Id, string? Error)> SaveIssueRequestAsync(int companyId, int branchId, PhIssueDoc d, bool submit, int userId);
    Task<string?> IssueStockAsync(int companyId, int branchId, int id, List<PhIssueLine> lines, string? remarks, int userId);
    Task<string?> ReceiveIssueAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId);
    Task<string?> CancelIssueAsync(int companyId, int branchId, int id, int userId);
    Task<string?> SaveCountsAsync(int companyId, int branchId, int id, Dictionary<int, decimal?> counts, int userId);
    Task<List<PhCycleRack>> CycleCountPlanAsync(int companyId, int branchId);
    Task<string?> CountActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<List<PhBatchCorrectionRow>> CorrectionsAsync(int companyId, int branchId, string? status);
    Task<(int Id, string? Error)> SaveCorrectionAsync(int companyId, int branchId, int batchId, string newBatchNo, DateTime newExpiry, decimal newMrp, string reason, int userId);
    Task<string?> CorrectionActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId);

    Task<int> MakerAsync(string table, int id);
    Task<List<int>> MatrixApproversAsync(int companyId, string moduleCode, int branchId);
    Task<PhDashboard> DashboardAsync(int companyId, int branchId);
}

/// <summary>
/// Pharmacy > Inventory through EMR.Api (api/pharmacy/inventory, SQLScripts/2360). Checks that need no data stay here;
/// stock moves, approvals and the books run in the stored procedures, each in one transaction, with the same messages.
/// </summary>
public class PharmacyInventoryService(PharmacyApiClient api) : IPharmacyInventoryService
{
    private const string Base = "api/pharmacy/inventory";
    private static string Q(params (string, object?)[] a) => PharmacyApiClient.Q(a);
    // lines for OPENJSON: property names exactly as the procedure reads them (PascalCase)
    private static string Json(object o) => JsonSerializer.Serialize(o);
    private static T Row<T>(JsonElement e) => e.Deserialize<T>(PharmacyApiClient.Json)!;
    private sealed class Res { public int Id { get; set; } public string? Error { get; set; } }

    // ── stock enquiry ───────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhStockRow>> StockAsync(int companyId, int branchId, string? search, int? categoryId, string filter, int? storeId = null) =>
        api.GetAsync<List<PhStockRow>>($"{Base}/stock" + Q(("companyId", companyId), ("branchId", branchId),
            ("search", string.IsNullOrWhiteSpace(search) ? null : search.Trim()), ("categoryId", categoryId), ("filter", filter), ("storeId", storeId)));

    public Task<List<PhLedgerRow>> LedgerAsync(int companyId, int branchId, int itemId, int? batchId) =>
        api.GetAsync<List<PhLedgerRow>>($"{Base}/ledger" + Q(("companyId", companyId), ("branchId", branchId), ("itemId", itemId), ("batchId", batchId)));

    public Task<List<PhStockRow>> BatchSearchAsync(int companyId, int branchId, string q, bool expiredOnly = false, int? storeId = null) =>
        api.GetAsync<List<PhStockRow>>($"{Base}/batch-search" + Q(("companyId", companyId), ("branchId", branchId), ("q", q), ("expiredOnly", expiredOnly), ("storeId", storeId)));

    public Task<List<PhOption>> OtherBranchesAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhOption>>($"{Base}/other-branches" + Q(("companyId", companyId), ("branchId", branchId)));

    // ── branch indent & transfer ────────────────────────────────────────────────────────────────────────
    public Task<List<PhInvDocRow>> TransfersAsync(int companyId, int branchId, string dir, string? status) =>
        api.GetAsync<List<PhInvDocRow>>($"{Base}/transfers" + Q(("companyId", companyId), ("branchId", branchId), ("dir", dir), ("status", status)));

    private async Task<PhInvDoc?> DocAsync(string url)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>(url);
        if (sets[0].Count == 0) return null;
        var d = Row<PhInvDoc>(sets[0][0]);
        d.Lines = sets[1].Select(Row<PhInvLine>).ToList();
        return d;
    }

    public Task<PhInvDoc?> GetTransferAsync(int companyId, int branchId, int id) => DocAsync($"{Base}/transfer/{id}" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<(int Id, string? Error)> SaveTransferRequestAsync(int companyId, int branchId, PhInvDoc d, bool submit, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (d.FromBranchId <= 0 || d.FromBranchId == branchId) return (0, "Pick the branch to ask from.");
        if (lines.Count == 0) return (0, "Add at least one item.");
        if (lines.Any(l => l.Qty <= 0)) return (0, "Every item needs a quantity.");
        if (lines.GroupBy(l => l.ItemId).Any(g => g.Count() > 1)) return (0, "An item is listed twice.");
        var r = await api.PostAsync<Res>($"{Base}/transfer/save", new
        {
            d.Id, companyId, branchId, userId, d.FromBranchId, d.Priority, d.Remarks, submit, Lines = Json(lines.Select(l => new { l.ItemId, l.Qty }))
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> DispatchAsync(int companyId, int branchId, int id, List<PhInvLine> lines, string? remarks, int userId, int? storeId = null)
    {
        lines = lines.Where(l => l.BatchId > 0 && l.DispatchQty > 0).ToList();
        if (lines.Count == 0) return "Pick the batches and quantities to send.";
        return (await api.PostAsync<Res>($"{Base}/transfer/dispatch", new
        {
            companyId, branchId, userId, id, remarks, Lines = Json(lines.Select(l => new { l.BatchId, l.DispatchQty })), storeId
        })).Error;
    }

    public async Task<string?> ReceiveAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId, int? storeId = null)
    {
        var keys = received.Keys.Union(reasons.Keys).Distinct();
        return (await api.PostAsync<Res>($"{Base}/transfer/receive", new
        {
            companyId, branchId, userId, id, remarks, storeId,
            Received = Json(keys.Select(k => new { LineId = k, Qty = received.TryGetValue(k, out var q) ? q : (decimal?)null, Reason = reasons.TryGetValue(k, out var w) ? w : null }))
        })).Error;
    }

    public async Task<string?> CancelTransferAsync(int companyId, int branchId, int id, int userId) =>
        (await api.PostAsync<Res>($"{Base}/transfer/cancel", new { companyId, branchId, userId, id, action = (string?)null, remarks = (string?)null })).Error;

    // ── stores and store issue (godown -> counter) ──────────────────────────────────────────────────────
    public Task<List<PhStoreOption>> StoresAsync(int companyId, int branchId, string purpose = "ANY") =>
        api.GetAsync<List<PhStoreOption>>($"{Base}/stores" + Q(("companyId", companyId), ("branchId", branchId), ("purpose", purpose)));

    public Task<List<PhPosBatch>> StoreBatchesAsync(int companyId, int branchId, int storeId, int itemId) =>
        api.GetAsync<List<PhPosBatch>>($"{Base}/store-batches" + Q(("companyId", companyId), ("branchId", branchId), ("storeId", storeId), ("itemId", itemId)));

    public Task<List<PhIssueRow>> IssuesAsync(int companyId, int branchId, string? status) =>
        api.GetAsync<List<PhIssueRow>>($"{Base}/issues" + Q(("companyId", companyId), ("branchId", branchId), ("status", status)));

    public async Task<PhIssueDoc?> GetIssueAsync(int companyId, int branchId, int id)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>($"{Base}/issue/{id}" + Q(("companyId", companyId), ("branchId", branchId)));
        if (sets[0].Count == 0) return null;
        var d = Row<PhIssueDoc>(sets[0][0]);
        d.Lines = sets[1].Select(Row<PhIssueLine>).ToList();
        return d;
    }

    public async Task<(int Id, string? Error)> SaveIssueRequestAsync(int companyId, int branchId, PhIssueDoc d, bool submit, int userId)
    {
        var lines = d.Lines.Where(l => l.ItemId > 0).ToList();
        if (d.FromStoreId <= 0 || d.ToStoreId <= 0) return (0, "Pick the store that gives and the store that receives.");
        if (d.FromStoreId == d.ToStoreId) return (0, "The giving and receiving store must be different.");
        if (lines.Count == 0) return (0, "Add at least one item.");
        if (lines.Any(l => l.RequestQty <= 0)) return (0, "Every item needs a quantity.");
        if (lines.GroupBy(l => l.ItemId).Any(g => g.Count() > 1)) return (0, "An item is listed twice.");
        var r = await api.PostAsync<Res>($"{Base}/issue/save", new
        {
            d.Id, companyId, branchId, userId, d.FromStoreId, d.ToStoreId, d.Remarks, submit, Lines = Json(lines.Select(l => new { l.ItemId, Qty = l.RequestQty, l.Remarks }))
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> IssueStockAsync(int companyId, int branchId, int id, List<PhIssueLine> lines, string? remarks, int userId)
    {
        lines = lines.Where(l => l.BatchId > 0 && l.IssueQty > 0).ToList();
        if (lines.Count == 0) return "Pick the batches and quantities to issue.";
        return (await api.PostAsync<Res>($"{Base}/issue/issue", new
        {
            companyId, branchId, userId, id, remarks, Lines = Json(lines.Select(l => new { l.BatchId, l.IssueQty }))
        })).Error;
    }

    public async Task<string?> ReceiveIssueAsync(int companyId, int branchId, int id, Dictionary<int, decimal> received, Dictionary<int, string> reasons, string? remarks, int userId)
    {
        var keys = received.Keys.Union(reasons.Keys).Distinct();
        return (await api.PostAsync<Res>($"{Base}/issue/receive", new
        {
            companyId, branchId, userId, id, remarks,
            Received = Json(keys.Select(k => new { LineId = k, Qty = received.TryGetValue(k, out var q) ? q : (decimal?)null, Reason = reasons.TryGetValue(k, out var w) ? w : null }))
        })).Error;
    }

    public async Task<string?> CancelIssueAsync(int companyId, int branchId, int id, int userId) =>
        (await api.PostAsync<Res>($"{Base}/issue/cancel", new { companyId, branchId, userId, id, action = (string?)null, remarks = (string?)null })).Error;

    // ── adjustment / write-off ──────────────────────────────────────────────────────────────────────────
    public Task<List<PhInvDocRow>> AdjustmentsAsync(int companyId, int branchId, string kind, string? status) =>
        api.GetAsync<List<PhInvDocRow>>($"{Base}/adjustments" + Q(("companyId", companyId), ("branchId", branchId), ("kind", kind), ("status", status)));

    public Task<PhInvDoc?> GetAdjustmentAsync(int companyId, int branchId, int id) => DocAsync($"{Base}/adjustment/{id}" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<(int Id, string? Error)> SaveAdjustmentAsync(int companyId, int branchId, PhInvDoc d, int userId)
    {
        var writeOff = d.Kind == "WRITEOFF";
        var lines = d.Lines.Where(l => l.BatchId > 0 && l.Qty != 0).ToList();
        if (d.ReasonId is null or 0) return (0, "Pick the reason.");
        if (lines.Count == 0) return (0, "Add at least one batch with a quantity.");
        if (lines.GroupBy(l => l.BatchId).Any(g => g.Count() > 1)) return (0, "A batch is listed twice.");
        if (writeOff) lines.ForEach(l => l.Qty = -Math.Abs(l.Qty));   // a write-off only takes stock out
        var r = await api.PostAsync<Res>($"{Base}/adjustment/save", new
        {
            d.Id, companyId, branchId, userId, Kind = writeOff ? "WRITEOFF" : "ADJUST", d.DocDate, ReasonId = d.ReasonId!.Value, d.Remarks, d.DisposalMethod, d.DisposalAgency,
            d.DisposalDate, d.Witness1, d.Witness2, d.CertificateNo, Lines = Json(lines.Select(l => new { l.BatchId, l.Qty, l.Remarks })), d.StoreId
        });
        return (r.Id, r.Error);
    }

    public async Task<string?> AdjustmentActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId) =>
        (await api.PostAsync<Res>($"{Base}/adjustment/action", new { companyId, branchId, userId, id, action, remarks })).Error;

    // ── physical stock verification ─────────────────────────────────────────────────────────────────────
    public Task<List<PhInvDocRow>> CountsAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhInvDocRow>>($"{Base}/counts" + Q(("companyId", companyId), ("branchId", branchId)));

    public Task<PhInvDoc?> GetCountAsync(int companyId, int branchId, int id) => DocAsync($"{Base}/count/{id}" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<(int Id, string? Error)> CreateCountAsync(int companyId, int branchId, string? rackPrefix, int? categoryId, bool includeZero, string? remarks, int userId, int? storeId = null)
    {
        var r = await api.PostAsync<Res>($"{Base}/count/create", new { companyId, branchId, userId, rackPrefix, categoryId, includeZero, remarks, storeId });
        return (r.Id, r.Error);
    }

    public async Task<string?> SaveCountsAsync(int companyId, int branchId, int id, Dictionary<int, decimal?> counts, int userId)
    {
        if (counts.Values.Any(v => v < 0)) return "A count cannot be negative.";
        return (await api.PostAsync<Res>($"{Base}/count/save", new { companyId, branchId, id, userId, Counts = Json(counts.Select(c => new { LineId = c.Key, Qty = c.Value })) })).Error;
    }

    public Task<List<PhCycleRack>> CycleCountPlanAsync(int companyId, int branchId) =>
        api.GetAsync<List<PhCycleRack>>($"{Base}/count/cycle-plan" + Q(("companyId", companyId), ("branchId", branchId)));

    public async Task<string?> CountActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId) =>
        (await api.PostAsync<Res>($"{Base}/count/action", new { companyId, branchId, userId, id, action, remarks })).Error;

    // ── batch correction ────────────────────────────────────────────────────────────────────────────────
    public Task<List<PhBatchCorrectionRow>> CorrectionsAsync(int companyId, int branchId, string? status) =>
        api.GetAsync<List<PhBatchCorrectionRow>>($"{Base}/corrections" + Q(("companyId", companyId), ("branchId", branchId), ("status", status)));

    public async Task<(int Id, string? Error)> SaveCorrectionAsync(int companyId, int branchId, int batchId, string newBatchNo, DateTime newExpiry, decimal newMrp, string reason, int userId)
    {
        newBatchNo = newBatchNo?.Trim().ToUpperInvariant() ?? "";
        newExpiry = new DateTime(newExpiry.Year, newExpiry.Month, DateTime.DaysInMonth(newExpiry.Year, newExpiry.Month));
        if (newBatchNo.Length is 0 or > 30) return (0, "Batch number is required (up to 30 characters).");
        if (newMrp <= 0) return (0, "MRP must be above zero.");
        if (string.IsNullOrWhiteSpace(reason)) return (0, "Give the reason for the correction (for the audit trail).");
        var r = await api.PostAsync<Res>($"{Base}/correction/save", new { companyId, branchId, userId, batchId, newBatchNo, newExpiry, newMrp, reason });
        return (r.Id, r.Error);
    }

    public async Task<string?> CorrectionActionAsync(int companyId, int branchId, int id, string action, string? remarks, int userId) =>
        (await api.PostAsync<Res>($"{Base}/correction/action", new { companyId, branchId, userId, id, action, remarks })).Error;

    // ── approvals ───────────────────────────────────────────────────────────────────────────────────────
    private sealed record MakerRow(int Maker);
    private sealed record UserRow(int UserId);

    public async Task<int> MakerAsync(string table, int id)
    {
        if (table is not ("adj" or "count" or "corr")) throw new ArgumentException(table);
        return (await api.GetAsync<MakerRow>($"{Base}/maker/{table}/{id}")).Maker;
    }

    /// <summary>Approvers named in the Approval Matrix for this module (branch-wise matrix first, else company-wise); empty = no matrix.</summary>
    public async Task<List<int>> MatrixApproversAsync(int companyId, string moduleCode, int branchId) =>
        (await api.GetAsync<List<UserRow>>($"{Base}/matrix-approvers" + Q(("companyId", companyId), ("moduleCode", moduleCode), ("branchId", branchId)))).Select(x => x.UserId).ToList();

    // ── dashboard ───────────────────────────────────────────────────────────────────────────────────────
    private sealed record ReorderRow(string ItemName, decimal Stock, decimal Reorder, string Uom);
    private sealed record CountsRow(int BelowReorder, int OutOfStock, decimal SupplierDue);
    private sealed record TopRow(string ItemName, decimal Qty, decimal Value);
    private sealed record DayRow(DateTime Day, decimal Value);
    private sealed record ModeRow(string Mode, decimal Amount);
    private sealed record Day14Row(DateTime Day, decimal Sales, decimal Purchases);

    public async Task<PhDashboard> DashboardAsync(int companyId, int branchId)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>($"{Base}/dashboard" + Q(("companyId", companyId), ("branchId", branchId)));
        var d = Row<PhDashboard>(sets[0][0]);
        d.Reorder = sets[1].Select(Row<ReorderRow>).Select(x => (x.ItemName, x.Stock, x.Reorder, x.Uom)).ToList();
        var c = Row<CountsRow>(sets[2][0]);
        d.BelowReorder = c.BelowReorder; d.OutOfStock = c.OutOfStock; d.SupplierDue = c.SupplierDue;
        d.TopItems = sets[3].Select(Row<TopRow>).Select(x => (x.ItemName, x.Qty, x.Value)).ToList();
        d.Last7 = sets[4].Select(Row<DayRow>).Select(x => (x.Day, x.Value)).ToList();
        if (sets.Count > 8)
        {
            d.Pending = sets[5].Select(Row<PhPendingRequest>).ToList();
            d.StoreStock = sets[6].Select(Row<PhStoreStockRow>).ToList();
            d.ModesToday = sets[7].Select(Row<ModeRow>).Select(x => (x.Mode, x.Amount)).ToList();
            d.Last14 = sets[8].Select(Row<Day14Row>).Select(x => (x.Day, x.Sales, x.Purchases)).ToList();
        }
        d.NearExpiry = (await StockAsync(companyId, branchId, null, null, "near")).OrderBy(r => r.ExpiryDate).Take(12).ToList();
        return d;
    }
}
