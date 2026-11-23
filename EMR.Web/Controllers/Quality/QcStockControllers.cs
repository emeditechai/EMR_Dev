using System.Text.Json;
using ClosedXML.Excel;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers.Quality;

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
// Quality & Compliance > Stock Management (SQLScripts/2498-2500). Lab reagent / consumable stock, separate from the
// pharmacy. Web -> EMR.Api api/qc/stock -> stored procedures; nothing here touches the database. Every action is mapped
// to a page control (Settings > Security); the screens only hide what the user may not do.
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

public sealed class QcStockActionBody
{
    public int Id { get; set; }
    public string? Remarks { get; set; }
    public JsonElement? Data { get; set; }
    public bool ReceiveNow { get; set; }
}

public sealed class QcStockDocSaveBody
{
    public int? DocId { get; set; }
    public DateTime? DocDate { get; set; }
    public int StoreId { get; set; }
    public int? ToStoreId { get; set; }
    public int? SupplierId { get; set; }
    public int? RefDocId { get; set; }
    public string? SupplierInvNo { get; set; }
    public DateTime? SupplierInvDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public bool IsInterState { get; set; }
    public string? ReasonCode { get; set; }
    public string? Priority { get; set; }
    public string? Terms { get; set; }
    public decimal? OtherCharges { get; set; }
    public string? Remarks { get; set; }
    public JsonElement Lines { get; set; }
}

[Authorize]
public abstract class QcStockControllerBase(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger logger) : Controller
{
    protected QcStockApiClient Api => api;
    protected static string Q(params (string Name, object? Value)[] args) => QcStockApiClient.Q(args);

    protected IActionResult Fail(string message) => Json(new { success = false, message });

    protected async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Stock API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    /// <summary>A write: the procedure's row (Success / Error); a success is written to the audit log.</summary>
    protected async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            var no = row.S("DocNo");
            try { await audit.LogAsync("Quality & Compliance", action, description + (no.Length > 0 ? $" ({no})" : ""), User.GetUserId(), User.GetCurrentBranchId()); }
            catch { /* audit only */ }
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Stock API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    /// <summary>Which of the page's controls the user holds, for showing buttons (the endpoint map still decides).</summary>
    protected async Task<Dictionary<string, bool>> PermsAsync(string page, params string[] controls)
    {
        var d = new Dictionary<string, bool>();
        foreach (var c in controls) d[c] = await guard.ShowsAsync(HttpContext, page, c);
        return d;
    }

    protected Task<bool> AllowsAsync(string page, string control) => guard.AllowsAsync(HttpContext, page, control);

    /// <summary>Stores, suppliers, items, adjustment reasons, settings and categories for the screens.</summary>
    protected async Task<object> LookupsAsync()
    {
        try
        {
            var s = await api.SetsAsync("/lookups");
            JsonElement Set(int i) => i < s.Count ? s[i] : JsonDocument.Parse("[]").RootElement;
            return new { stores = Set(0), suppliers = Set(1), items = Set(2), reasons = Set(3), settings = s.First(4), categories = Set(5), error = (string?)null };
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException)
        {
            logger.LogWarning(ex, "Stock lookups failed");
            return new { stores = Array.Empty<object>(), suppliers = Array.Empty<object>(), items = Array.Empty<object>(), reasons = Array.Empty<object>(),
                         settings = (object?)null, categories = Array.Empty<object>(), error = (string?)ex.Message };
        }
    }

    protected object Me() => new { userId = User.GetUserId(), branchId = User.GetCurrentBranchId(), isSuperAdmin = User.IsSuperAdmin() };
}

// ── the document screens (opening stock, PO, GRN, return, indent, issue, adjustment, count) ─────────────────────
public abstract class QcStockDocControllerBase(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    protected abstract string DocType { get; }
    protected abstract string PageCode { get; }
    protected abstract string Title { get; }
    protected abstract string[] Controls { get; }

    [HttpGet]
    public async Task<IActionResult> Index(int? open)
    {
        ViewData["Title"] = Title;
        ViewBag.Config = JsonSerializer.Serialize(new
        {
            docType = DocType, title = Title, page = PageCode, controller = ControllerContext.ActionDescriptor.ControllerName, open,
            perms = await PermsAsync(PageCode, Controls), lookups = await LookupsAsync(), me = Me()
        });
        return View("~/Views/Quality/Stock/Doc.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? status, DateTime? from, DateTime? to, string? search, string? scope, int? storeId) => Read(async () =>
        await Api.GetAsync("/docs" + Q(("docType", DocType), ("status", status), ("from", from), ("to", to), ("search", search), ("scope", scope), ("storeId", storeId))));

    [HttpGet]
    public Task<IActionResult> Get(int id) => Read(async () => await Api.SetsAsync($"/doc/{id}" + Q(("docType", DocType))));

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        try
        {
            var sets = await Api.SetsAsync($"/doc/{id}" + Q(("docType", DocType)));
            if (!sets.First(0).Has()) return NotFound();
            ViewBag.Sets = sets;
            return View("~/Views/Quality/Stock/Print.cshtml");
        }
        catch (InvalidOperationException ex) { return Content(ex.Message); }
    }

    [HttpGet]
    public Task<IActionResult> Lots(int storeId, int itemId, string? purpose) => Read(async () =>
        await Api.GetAsync("/lots-for-pick" + Q(("storeId", storeId), ("itemId", itemId), ("purpose", purpose))));

    [HttpPost]
    public Task<IActionResult> Save([FromBody] QcStockDocSaveBody b) => Write(async () => await Api.PostAsync("/doc/save", new
    {
        b.DocId, DocType, b.DocDate, b.StoreId, b.ToStoreId, b.SupplierId, b.RefDocId, b.SupplierInvNo, b.SupplierInvDate, b.ExpectedDate, b.IsInterState,
        b.ReasonCode, b.Priority, b.Terms, b.OtherCharges, b.Remarks,
        Lines = b.Lines.ValueKind == JsonValueKind.Array ? b.Lines.GetRawText() : "[]"   // PascalCase keys as the page sends them (OPENJSON)
    }), $"QC.{DocType}.Saved", $"{Title} draft saved");

    protected Task<IActionResult> DoAction(QcStockActionBody b, string action) => Write(async () => await Api.PostAsync("/doc/action", new
    {
        DocId = b.Id, DocType, Action = action, b.Remarks,
        Data = b.Data is { ValueKind: JsonValueKind.Array or JsonValueKind.Object } d ? d.GetRawText() : null,
        IsSuperAdmin = User.IsSuperAdmin()
    }), $"QC.{DocType}.{action}", $"{Title} {action.ToLowerInvariant().Replace('_', ' ')}");

    [HttpPost] public Task<IActionResult> Submit([FromBody] QcStockActionBody b) => DoAction(b, "SUBMIT");
    [HttpPost] public Task<IActionResult> Approve([FromBody] QcStockActionBody b) => DoAction(b, "APPROVE");
    [HttpPost] public Task<IActionResult> Reject([FromBody] QcStockActionBody b) => DoAction(b, "REJECT");
    [HttpPost] public Task<IActionResult> Post([FromBody] QcStockActionBody b) => DoAction(b, "POST");
    [HttpPost] public Task<IActionResult> Cancel([FromBody] QcStockActionBody b) => DoAction(b, "CANCEL");
    [HttpPost] public Task<IActionResult> Close([FromBody] QcStockActionBody b) => DoAction(b, "CLOSE");
}

public class QcOpeningStockController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcOpeningStockController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "OPN";
    protected override string PageCode => "QC.STOCK.OPENING";
    protected override string Title => "Opening Stock";
    protected override string[] Controls => ["ADD", "POST", "CANCEL"];
}

public class QcPurchaseOrdersController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcPurchaseOrdersController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "PO";
    protected override string PageCode => "QC.STOCK.PO";
    protected override string Title => "Purchase Orders";
    protected override string[] Controls => ["ADD", "SUBMIT", "APPROVE", "CANCEL", "CLOSE"];

    /// <summary>Items at or below reorder level, with a suggested quantity (to fill a new order).</summary>
    [HttpGet]
    public Task<IActionResult> Reorder() => Read(async () => await Api.GetAsync("/reorder"));
}

public class QcGoodsReceiptsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcGoodsReceiptsController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "GRN";
    protected override string PageCode => "QC.STOCK.GRN";
    protected override string Title => "Goods Receipt (GRN)";
    protected override string[] Controls => ["ADD", "POST", "CANCEL"];

    /// <summary>Approved / part-received purchase orders of this branch.</summary>
    [HttpGet]
    public Task<IActionResult> OpenOrders(int? supplierId) => Read(async () =>
        await Api.GetAsync("/docs" + Q(("docType", "PO"), ("status", "OPEN"))));

    /// <summary>A purchase order with its pending quantities (to receive against it).</summary>
    [HttpGet]
    public Task<IActionResult> Order(int id) => Read(async () => await Api.SetsAsync($"/doc/{id}" + Q(("docType", "PO"))));
}

public class QcPurchaseReturnsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcPurchaseReturnsController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "PRET";
    protected override string PageCode => "QC.STOCK.PRET";
    protected override string Title => "Purchase Returns";
    protected override string[] Controls => ["ADD", "POST", "CANCEL"];

    /// <summary>Posted goods receipts of this branch (to return against).</summary>
    [HttpGet]
    public Task<IActionResult> Receipts(int? supplierId) => Read(async () => await Api.GetAsync("/docs" + Q(("docType", "GRN"), ("status", "POSTED"))));
}

public class QcIndentsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcIndentsController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "IND";
    protected override string PageCode => "QC.STOCK.INDENT";
    protected override string Title => "Indents";
    protected override string[] Controls => ["ADD", "SUBMIT", "CANCEL", "REJECT", "CLOSE"];
}

public class QcStockIssuesController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockIssuesController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "ISS";
    protected override string PageCode => "QC.STOCK.ISSUE";
    protected override string Title => "Issue / Transfer";
    protected override string[] Controls => ["ADD", "DISPATCH", "RECEIVE", "CANCEL"];

    [HttpPost]
    public async Task<IActionResult> Dispatch([FromBody] QcStockActionBody b)
    {
        if (b.ReceiveNow && !await AllowsAsync(PageCode, "RECEIVE")) return Fail("You may dispatch but not receive; the receiving store must receive it.");
        return await DoAction(b, b.ReceiveNow ? "DISPATCH_RECEIVE" : "DISPATCH");
    }

    [HttpPost] public Task<IActionResult> Receive([FromBody] QcStockActionBody b) => DoAction(b, "RECEIVE");

    /// <summary>FEFO allocation of a quantity over the usable lots of a store.</summary>
    [HttpGet]
    public Task<IActionResult> Fefo(int storeId, int itemId, decimal qty) => Read(async () =>
        await Api.GetAsync("/fefo" + Q(("storeId", storeId), ("itemId", itemId), ("qty", qty))));

    /// <summary>Indents raised on this branch's stores, still to issue.</summary>
    [HttpGet]
    public Task<IActionResult> OpenIndents() => Read(async () => await Api.GetAsync("/docs" + Q(("docType", "IND"), ("status", "OPEN"), ("scope", "IN"))));

    /// <summary>An indent's pending lines allocated FEFO from the supplying store.</summary>
    [HttpGet]
    public Task<IActionResult> FromIndent(int id) => Read(async () => await Api.GetAsync($"/indent-for-issue/{id}"));
}

public class QcStockAdjustmentsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockAdjustmentsController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "ADJ";
    protected override string PageCode => "QC.STOCK.ADJUST";
    protected override string Title => "Adjustment / Write-off";
    protected override string[] Controls => ["ADD", "SUBMIT", "APPROVE", "CANCEL"];
}

public sealed class QcCountCreateBody
{
    public int StoreId { get; set; }
    public int? CategoryId { get; set; }
    public bool IncludeZero { get; set; }
    public string? Remarks { get; set; }
}

public class QcStockCountsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockCountsController> logger)
    : QcStockDocControllerBase(api, guard, audit, logger)
{
    protected override string DocType => "CNT";
    protected override string PageCode => "QC.STOCK.COUNT";
    protected override string Title => "Physical Stock Count";
    protected override string[] Controls => ["ADD", "SUBMIT", "APPROVE", "CANCEL"];

    [HttpPost]
    public Task<IActionResult> Create([FromBody] QcCountCreateBody b) => Write(async () =>
        await Api.PostAsync("/count/create", new { b.StoreId, b.CategoryId, b.IncludeZero, b.Remarks }), "QC.CNT.Created", "Stock count started");

    /// <summary>Counted quantities: Data = [{ LineId, CountedQty, Remarks }] and lots found that were not listed [{ LotId, CountedQty }].</summary>
    [HttpPost]
    public Task<IActionResult> SaveCounts([FromBody] QcStockActionBody b) => DoAction(b, "COUNTS");
}

// ── Stock Dashboard ────────────────────────────────────────────────────────────────────────────────────────
public sealed class QcStockSettingsBody
{
    public bool PoApprovalRequired { get; set; }
    public bool AdjApprovalRequired { get; set; }
    public bool CountApprovalRequired { get; set; }
    public bool LotAcceptanceRequired { get; set; }
    public bool DeductOnConsumption { get; set; }
    public int NearExpiryDays { get; set; }
}

public class QcStockDashboardController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockDashboardController> logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    private const string Page = "QC.STOCK.DASHBOARD";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Config = JsonSerializer.Serialize(new { perms = await PermsAsync(Page, "SETTINGS", "POST_ACCOUNTS"), me = Me() });
        return View("~/Views/Quality/Stock/Dashboard.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> Data() => Read(async () => await Api.SetsAsync("/dashboard"));

    [HttpPost]
    public Task<IActionResult> SaveSettings([FromBody] QcStockSettingsBody b) => Write(async () => await Api.PostAsync("/settings", b),
        "QC.STOCK.Settings", $"Stock settings: PO approval {b.PoApprovalRequired}, adjustment approval {b.AdjApprovalRequired}, count approval {b.CountApprovalRequired}, " +
                             $"lot acceptance {b.LotAcceptanceRequired}, deduct on consumption {b.DeductOnConsumption}, near expiry {b.NearExpiryDays} days");

    [HttpPost]
    public Task<IActionResult> PostConsumption() => Write(async () => await Api.PostAsync("/post-consumption", new { }),
        "QC.STOCK.PostConsumption", "Lab consumption posted to accounts");
}

// ── Stock Enquiry ──────────────────────────────────────────────────────────────────────────────────────────
public sealed class QcMarkOpenedBody
{
    public int StoreId { get; set; }
    public int LotId { get; set; }
    public DateTime? OpenedOn { get; set; }
    public bool Clear { get; set; }
}

public class QcStockEnquiryController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockEnquiryController> logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    private const string Page = "QC.STOCK.ENQUIRY";

    [HttpGet]
    public async Task<IActionResult> Index(string? filter)
    {
        ViewBag.Config = JsonSerializer.Serialize(new { perms = await PermsAsync(Page, "OPEN_VIAL"), lookups = await LookupsAsync(), filter, me = Me() });
        return View("~/Views/Quality/Stock/Enquiry.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(int? storeId, string? view, string? filter, string? search, int? categoryId) => Read(async () =>
        await Api.GetAsync("/stock" + Q(("storeId", storeId), ("view", view), ("filter", filter), ("search", search), ("categoryId", categoryId))));

    [HttpGet]
    public Task<IActionResult> Ledger(int itemId, int? storeId, int? lotId, DateTime? from, DateTime? to) => Read(async () =>
        await Api.SetsAsync("/ledger" + Q(("itemId", itemId), ("storeId", storeId), ("lotId", lotId), ("from", from), ("to", to))));

    [HttpPost]
    public Task<IActionResult> MarkOpened([FromBody] QcMarkOpenedBody b) => Write(async () => await Api.PostAsync("/mark-opened", b),
        "QC.STOCK.Opened", b.Clear ? $"Lot #{b.LotId} opened date cleared" : $"Lot #{b.LotId} marked opened on {b.OpenedOn:dd-MMM-yyyy}");
}

// ── Lot Acceptance ─────────────────────────────────────────────────────────────────────────────────────────
public sealed class QcLotActionBody
{
    public int LotId { get; set; }
    public string? Note { get; set; }
}

public class QcLotAcceptanceController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcLotAcceptanceController> logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    private const string Page = "QC.STOCK.LOTS";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Config = JsonSerializer.Serialize(new { perms = await PermsAsync(Page, "ACCEPT", "REJECT", "BLOCK"), me = Me() });
        return View("~/Views/Quality/Stock/Lots.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? status, string? search) => Read(async () => await Api.GetAsync("/lots" + Q(("status", status), ("search", search))));

    private Task<IActionResult> Act(QcLotActionBody b, string action) => Write(async () => await Api.PostAsync("/lot/action", new { b.LotId, Action = action, b.Note }),
        $"QC.LOT.{action}", $"Lot #{b.LotId} {action.ToLowerInvariant()}: {b.Note}");

    [HttpPost] public Task<IActionResult> Accept([FromBody] QcLotActionBody b) => Act(b, "ACCEPT");
    [HttpPost] public Task<IActionResult> Reject([FromBody] QcLotActionBody b) => Act(b, "REJECT");
    [HttpPost] public Task<IActionResult> Block([FromBody] QcLotActionBody b) => Act(b, "BLOCK");
    [HttpPost] public Task<IActionResult> Unblock([FromBody] QcLotActionBody b) => Act(b, "UNBLOCK");
}

// ── Pending Consumption ────────────────────────────────────────────────────────────────────────────────────
public sealed class QcLinesBody
{
    public List<int> LineIds { get; set; } = new();
    public string? Reason { get; set; }
}

public class QcPendingConsumptionController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcPendingConsumptionController> logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    private const string Page = "QC.STOCK.PENDING";

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Config = JsonSerializer.Serialize(new { perms = await PermsAsync(Page, "RETRY", "SKIP"), me = Me() });
        return View("~/Views/Quality/Stock/Pending.cshtml");
    }

    [HttpGet]
    public Task<IActionResult> List(string? status, DateTime? from, DateTime? to) => Read(async () =>
        await Api.GetAsync("/pending" + Q(("status", status), ("from", from), ("to", to))));

    [HttpPost]
    public Task<IActionResult> Retry([FromBody] QcLinesBody b) => Write(async () => await Api.PostAsync("/pending/retry", new { LineIds = string.Join(",", b.LineIds) }),
        "QC.STOCK.PendingRetry", $"Pending consumption retried ({b.LineIds.Count} lines)");

    [HttpPost]
    public Task<IActionResult> Skip([FromBody] QcLinesBody b) => Write(async () => await Api.PostAsync("/pending/skip", new { LineIds = string.Join(",", b.LineIds), b.Reason }),
        "QC.STOCK.PendingSkip", $"Pending consumption skipped ({b.LineIds.Count} lines): {b.Reason}");
}

// ── Stock Reports ──────────────────────────────────────────────────────────────────────────────────────────
public class QcStockReportsController(QcStockApiClient api, IActionPermissionGuard guard, IAuditLogService audit, ILogger<QcStockReportsController> logger)
    : QcStockControllerBase(api, guard, audit, logger)
{
    private const string Page = "QC.STOCK.REPORTS";

    public static readonly (string Key, string Title, string Filters)[] Reports =
    [
        ("STOCK", "Stock summary (by store and item)", "store,item,category"),
        ("LOTS", "Lot-wise stock (expiry, status, opened)", "store,item,category"),
        ("SUMMARY", "Stock movement summary (opening, in, out, closing)", "dates,store,item,category"),
        ("VALUATION", "Stock valuation as on date", "asOn,store,item,category"),
        ("MOVEMENT", "Stock ledger (every movement)", "dates,store,item,category"),
        ("EXPIRY", "Expired and near-expiry stock", "days,store,category"),
        ("PURCHASE", "Purchase register (GRN, with GST)", "dates,store,item,supplier"),
        ("SUPPLIER", "Supplier-wise purchases and returns", "dates,supplier"),
        ("PO", "Purchase order status", "dates,item,supplier"),
        ("ISSUE", "Issue / transfer register", "dates,store,item"),
        ("ADJUST", "Adjustment, write-off and count differences", "dates,store,item"),
        ("CONSUMPTION", "Consumption (tests, QC use, write-off)", "dates,store,item,category"),
        ("TRACE", "Lot traceability (receipt to patient bill)", "dates,lot,item"),
        ("FSN", "Fast / slow / non-moving items", "days,category")
    ];

    [HttpGet]
    public async Task<IActionResult> Index(string? report)
    {
        ViewBag.Config = JsonSerializer.Serialize(new
        {
            report, perms = await PermsAsync(Page, "EXPORT"), lookups = await LookupsAsync(), me = Me(),
            reports = Reports.Select(r => new { key = r.Key, title = r.Title, filters = r.Filters.Split(',') })
        });
        return View("~/Views/Quality/Stock/Reports.cshtml");
    }

    private Task<JsonElement> Fetch(string report, DateTime? from, DateTime? to, int? storeId, int? itemId, int? supplierId, int? categoryId, int? days, string? search) =>
        Api.GetAsync($"/report/{Uri.EscapeDataString(report)}" + Q(("from", from), ("to", to), ("storeId", storeId), ("itemId", itemId), ("supplierId", supplierId),
            ("categoryId", categoryId), ("days", days), ("search", search)));

    [HttpGet]
    public Task<IActionResult> Data(string report, DateTime? from, DateTime? to, int? storeId, int? itemId, int? supplierId, int? categoryId, int? days, string? search) =>
        Read(async () => await Fetch(report, from, to, storeId, itemId, supplierId, categoryId, days, search));

    [HttpGet]
    public async Task<IActionResult> Export(string report, DateTime? from, DateTime? to, int? storeId, int? itemId, int? supplierId, int? categoryId, int? days, string? search)
    {
        var def = Reports.FirstOrDefault(r => r.Key.Equals(report, StringComparison.OrdinalIgnoreCase));
        if (def.Key is null) return BadRequest("Unknown report.");
        JsonElement rows;
        try { rows = await Fetch(def.Key, from, to, storeId, itemId, supplierId, categoryId, days, search); }
        catch (InvalidOperationException ex) { return Content(ex.Message); }

        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("Report");
        ws.Cell(1, 1).Value = def.Title;
        ws.Cell(1, 1).Style.Font.Bold = true; ws.Cell(1, 1).Style.Font.FontSize = 13;
        ws.Cell(2, 1).Value = $"Printed {DateTime.Now:dd-MMM-yyyy HH:mm}" + (from.HasValue || to.HasValue ? $" · {from:dd-MMM-yyyy} to {to:dd-MMM-yyyy}" : "");
        var list = rows.Items();
        if (list.Count > 0)
        {
            var cols = list[0].EnumerateObject().Select(p => p.Name).ToList();
            for (var c = 0; c < cols.Count; c++) { var h = ws.Cell(4, c + 1); h.Value = cols[c]; h.Style.Font.Bold = true; h.Style.Fill.BackgroundColor = XLColor.FromHtml("#e7f1ff"); }
            for (var r = 0; r < list.Count; r++)
                for (var c = 0; c < cols.Count; c++)
                {
                    var cell = ws.Cell(r + 5, c + 1);
                    var v = list[r].Prop(cols[c]);
                    if (v is null) continue;
                    var e = v.Value;
                    if (e.ValueKind == JsonValueKind.Number) cell.Value = e.GetDecimal();
                    else if (e.ValueKind == JsonValueKind.True || e.ValueKind == JsonValueKind.False) cell.Value = e.GetBoolean() ? "Yes" : "No";
                    else if (e.ValueKind == JsonValueKind.String && e.GetString() is { Length: >= 10 } s && DateTime.TryParse(s, out var d) && s[4] == '-')
                    { cell.Value = d; cell.Style.DateFormat.Format = d.TimeOfDay == TimeSpan.Zero ? "dd-mmm-yyyy" : "dd-mmm-yyyy hh:mm"; }
                    else cell.Value = e.ToString();
                }
            ws.Range(4, 1, 4 + list.Count, cols.Count).SetAutoFilter();
            ws.Columns().AdjustToContents(4, Math.Min(list.Count + 4, 300));
            ws.SheetView.FreezeRows(4);
        }
        else ws.Cell(4, 1).Value = "No rows for these filters.";
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        await audit.LogAsync("Quality & Compliance", "QC.STOCK.ReportExport", $"Stock report {def.Key} exported ({list.Count} rows)", User.GetUserId(), User.GetCurrentBranchId());
        return File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"Stock-{def.Key.ToLowerInvariant()}-{DateTime.Now:yyyyMMdd-HHmm}.xlsx");
    }
}
