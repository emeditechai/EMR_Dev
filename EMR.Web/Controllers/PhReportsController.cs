using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Reports;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using static EMR.Web.ApiClients.PharmacyApiClient;

namespace EMR.Web.Controllers;

/// <summary>
/// Reports > Pharmacy (SQLScripts/2361), read through EMR.Api (api/pharmacy/reports). One page per report
/// (REPORTS.PHARMACY.*: VIEW = page and data, EXPORT = Excel / PDF), all drawn by Views/PhReports/Report.cshtml from
/// <see cref="PharmacyReportDefs"/>. The Super Admin may pick any branch or all branches; everyone else sees their branch.
/// </summary>
[Authorize]
public class PhReportsController(PharmacyApiClient api, IAuditLogService audit, ILogger<PhReportsController> logger) : Controller
{
    private int CurrentBranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    /// <summary>Filter values of a report run (query string of the page).</summary>
    public sealed class PhRptQuery
    {
        public DateTime? From { get; set; }
        public DateTime? To { get; set; }
        public int? Branch { get; set; }        // Super Admin only; 0 = all branches
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 50;
        public int? User { get; set; }
        public string? Mode { get; set; }
        public string? Kind { get; set; }
        public int? Category { get; set; }
        public int? Manufacturer { get; set; }
        public string? Schedule { get; set; }
        public string? Search { get; set; }
        public string? Option { get; set; }
        public int? Supplier { get; set; }
        public int? Store { get; set; }
        public int? Party { get; set; }
    }

    // ── S1-S12 sales: page, data, export ──────────────────────────────────────────────────────────────────────
    [HttpGet] public Task<IActionResult> SalesRegister() => PageOf();
    [HttpGet] public Task<IActionResult> SalesRegisterData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SalesRegisterExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> SalesSummary() => PageOf();
    [HttpGet] public Task<IActionResult> SalesSummaryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SalesSummaryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> ItemSales() => PageOf();
    [HttpGet] public Task<IActionResult> ItemSalesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ItemSalesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Collections() => PageOf();
    [HttpGet] public Task<IActionResult> CollectionsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CollectionsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> UserSales() => PageOf();
    [HttpGet] public Task<IActionResult> UserSalesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> UserSalesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> SaleReturns() => PageOf();
    [HttpGet] public Task<IActionResult> SaleReturnsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SaleReturnsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Cancellations() => PageOf();
    [HttpGet] public Task<IActionResult> CancellationsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CancellationsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Discounts() => PageOf();
    [HttpGet] public Task<IActionResult> DiscountsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> DiscountsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> DoctorSales() => PageOf();
    [HttpGet] public Task<IActionResult> DoctorSalesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> DoctorSalesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> CustomerHistory() => PageOf();
    [HttpGet] public Task<IActionResult> CustomerHistoryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CustomerHistoryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> CreditAgeing() => PageOf();
    [HttpGet] public Task<IActionResult> CreditAgeingData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CreditAgeingExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> HourlyPattern() => PageOf();
    [HttpGet] public Task<IActionResult> HourlyPatternData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> HourlyPatternExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // P1-P9 purchase (SQLScripts/2362)
    [HttpGet] public Task<IActionResult> PurchaseRegister() => PageOf();
    [HttpGet] public Task<IActionResult> PurchaseRegisterData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> PurchaseRegisterExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> ItemPurchases() => PageOf();
    [HttpGet] public Task<IActionResult> ItemPurchasesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ItemPurchasesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> SupplierPurchases() => PageOf();
    [HttpGet] public Task<IActionResult> SupplierPurchasesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SupplierPurchasesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> PurchaseReturns() => PageOf();
    [HttpGet] public Task<IActionResult> PurchaseReturnsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> PurchaseReturnsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> PendingPos() => PageOf();
    [HttpGet] public Task<IActionResult> PendingPosData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> PendingPosExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> SupplierAgeing() => PageOf();
    [HttpGet] public Task<IActionResult> SupplierAgeingData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SupplierAgeingExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> SupplierPayments() => PageOf();
    [HttpGet] public Task<IActionResult> SupplierPaymentsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SupplierPaymentsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> RateVariation() => PageOf();
    [HttpGet] public Task<IActionResult> RateVariationData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> RateVariationExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> SchemeMargin() => PageOf();
    [HttpGet] public Task<IActionResult> SchemeMarginData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> SchemeMarginExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> IndentTurnaround() => PageOf();
    [HttpGet] public Task<IActionResult> IndentTurnaroundData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> IndentTurnaroundExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // I1-I13 stock & inventory (SQLScripts/2363)
    [HttpGet] public Task<IActionResult> CurrentStock() => PageOf();
    [HttpGet] public Task<IActionResult> CurrentStockData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CurrentStockExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> StockSummary() => PageOf();
    [HttpGet] public Task<IActionResult> StockSummaryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> StockSummaryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> ItemLedger() => PageOf();
    [HttpGet] public Task<IActionResult> ItemLedgerData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ItemLedgerExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> StockStatement() => PageOf();
    [HttpGet] public Task<IActionResult> StockStatementData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> StockStatementExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Reorder() => PageOf();
    [HttpGet] public Task<IActionResult> ReorderData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ReorderExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> NonMoving() => PageOf();
    [HttpGet] public Task<IActionResult> NonMovingData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> NonMovingExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> AbcAnalysis() => PageOf();
    [HttpGet] public Task<IActionResult> AbcAnalysisData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> AbcAnalysisExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> FsnAnalysis() => PageOf();
    [HttpGet] public Task<IActionResult> FsnAnalysisData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> FsnAnalysisExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> AbcVed() => PageOf();
    [HttpGet] public Task<IActionResult> AbcVedData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> AbcVedExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> DeadStock() => PageOf();
    [HttpGet] public Task<IActionResult> DeadStockData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> DeadStockExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Transfers() => PageOf();
    [HttpGet] public Task<IActionResult> TransfersData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> TransfersExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> Adjustments() => PageOf();
    [HttpGet] public Task<IActionResult> AdjustmentsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> AdjustmentsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> CountVariance() => PageOf();
    [HttpGet] public Task<IActionResult> CountVarianceData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CountVarianceExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> BatchCorrections() => PageOf();
    [HttpGet] public Task<IActionResult> BatchCorrectionsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> BatchCorrectionsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    [HttpGet] public Task<IActionResult> StockTurnover() => PageOf();
    [HttpGet] public Task<IActionResult> StockTurnoverData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> StockTurnoverExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // I14 store issue register (SQLScripts/2365)
    [HttpGet] public Task<IActionResult> StoreIssues() => PageOf();
    [HttpGet] public Task<IActionResult> StoreIssuesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> StoreIssuesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // E1-E4 expiry & quality (SQLScripts/2369)
    [HttpGet] public Task<IActionResult> NearExpiry() => PageOf();
    [HttpGet] public Task<IActionResult> NearExpiryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> NearExpiryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> ExpiredStock() => PageOf();
    [HttpGet] public Task<IActionResult> ExpiredStockData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ExpiredStockExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> ExpiryLoss() => PageOf();
    [HttpGet] public Task<IActionResult> ExpiryLossData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ExpiryLossExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> ShortExpiryReceipts() => PageOf();
    [HttpGet] public Task<IActionResult> ShortExpiryReceiptsData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> ShortExpiryReceiptsExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // G1-G6 GST & tax (SQLScripts/2370)
    [HttpGet] public Task<IActionResult> Gstr1Summary() => PageOf();
    [HttpGet] public Task<IActionResult> Gstr1SummaryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> Gstr1SummaryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> HsnSummary() => PageOf();
    [HttpGet] public Task<IActionResult> HsnSummaryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> HsnSummaryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> CreditNotes() => PageOf();
    [HttpGet] public Task<IActionResult> CreditNotesData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CreditNotesExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> PurchaseItc() => PageOf();
    [HttpGet] public Task<IActionResult> PurchaseItcData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> PurchaseItcExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> Gstr3b() => PageOf();
    [HttpGet] public Task<IActionResult> Gstr3bData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> Gstr3bExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> GstRateSummary() => PageOf();
    [HttpGet] public Task<IActionResult> GstRateSummaryData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> GstRateSummaryExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // F1-F5 finance & accounts (SQLScripts/2371)
    [HttpGet] public Task<IActionResult> CashierClosing() => PageOf();
    [HttpGet] public Task<IActionResult> CashierClosingData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> CashierClosingExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> GrossProfit() => PageOf();
    [HttpGet] public Task<IActionResult> GrossProfitData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> GrossProfitExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> TradingAccount() => PageOf();
    [HttpGet] public Task<IActionResult> TradingAccountData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> TradingAccountExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> StockVsBooks() => PageOf();
    [HttpGet] public Task<IActionResult> StockVsBooksData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> StockVsBooksExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> PartyLedger() => PageOf();
    [HttpGet] public Task<IActionResult> PartyLedgerData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> PartyLedgerExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    // C2-C3 statutory & compliance (SQLScripts/2372)
    [HttpGet] public Task<IActionResult> NdpsRegister() => PageOf();
    [HttpGet] public Task<IActionResult> NdpsRegisterData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> NdpsRegisterExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);
    [HttpGet] public Task<IActionResult> RxSalesRegister() => PageOf();
    [HttpGet] public Task<IActionResult> RxSalesRegisterData([FromQuery] PhRptQuery q) => DataOf(q);
    [HttpGet] public Task<IActionResult> RxSalesRegisterExport(string format, [FromQuery] PhRptQuery q) => ExportOf(format, q);

    /// <summary>GSTR-1 Excel in the GSTN offline tool's layout (b2b, b2cs, cdnr, cdnur, hsn, docs) for the chosen period and branch.</summary>
    [HttpGet]
    public async Task<IActionResult> Gstr1Excel([FromQuery] PhRptQuery q)
    {
        var def = PharmacyReportDefs.ByAction("Gstr1Summary")!;
        if (Validate(def, q) is { } err) return BadRequest(err);
        var (from, to) = Dates(def, q);
        try
        {
            var sets = await api.GetAsync<List<List<Dictionary<string, JsonElement>>>>("api/pharmacy/gst/gstr1" + Q(("companyId", CompanyId), ("branchId", BranchOf(q)), ("from", from), ("to", to)));
            var file = EMR.Web.Services.Reports.Gstr1Excel.Build(sets);
            try { await audit.LogAsync("REPORT_EXPORT", "PhReports.Gstr1Excel", $"GSTR-1 Excel {from:dd-MMM-yyyy} to {to:dd-MMM-yyyy}", User.GetUserId(), CurrentBranchId); } catch { }
            return File(file, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"GSTR1_{from:MMyyyy}_{(BranchOf(q) is int b ? "B" + b : "ALL")}.xlsx");
        }
        catch (Exception ex) { logger.LogError(ex, "GSTR-1 Excel failed"); return StatusCode(StatusCodes.Status502BadGateway, "The GSTR-1 Excel could not be made: " + ex.Message); }
    }

    /// <summary>Upload the GSTR-2B Excel (downloaded from the GST portal): purchase invoices of the period matched with it.</summary>
    [HttpPost, ValidateAntiForgeryToken, RequestSizeLimit(20 * 1024 * 1024)]
    public async Task<IActionResult> Gstr2bReconcile([FromQuery] PhRptQuery q, IFormFile? file)
    {
        var def = PharmacyReportDefs.ByAction("PurchaseItc")!;
        if (Validate(def, q) is { } err) return Json(new { error = err });
        if (file == null || file.Length == 0) return Json(new { error = "Choose the GSTR-2B Excel downloaded from the GST portal." });
        var (from, to) = Dates(def, q);
        try
        {
            var fields = new List<(string, string)> { ("companyId", CompanyId.ToString()), ("from", from.ToString("yyyy-MM-dd")), ("to", to.ToString("yyyy-MM-dd")) };
            if (BranchOf(q) is int b) fields.Add(("branchId", b.ToString()));
            var res = await api.PostFileAsync<JsonElement>("api/pharmacy/gst/gstr2b-reconcile", file, fields.ToArray());
            try { await audit.LogAsync("REPORT_EXPORT", "PhReports.Gstr2bReconcile", $"GSTR-2B reconciled {from:dd-MMM-yyyy} to {to:dd-MMM-yyyy}: {file.FileName}", User.GetUserId(), CurrentBranchId); } catch { }
            return Json(new { ok = true, data = res });
        }
        catch (Exception ex) { return Json(new { error = ex.Message }); }
    }

    // ── shared ──────────────────────────────────────────────────────────────────────────────────────────
    private PhRptDef Def()
    {
        var action = (string)RouteData.Values["action"]!;
        foreach (var suffix in new[] { "Data", "Export" })
            if (action.EndsWith(suffix, StringComparison.Ordinal) && PharmacyReportDefs.ByAction(action[..^suffix.Length]) is { } d) return d;
        return PharmacyReportDefs.ByAction(action)!;
    }

    private async Task<IActionResult> PageOf()
    {
        var def = Def();
        var lists = await ListsAsync(User.IsSuperAdmin() ? null : CurrentBranchId);
        ViewBag.Lists = lists;
        ViewBag.IsSuperAdmin = User.IsSuperAdmin();
        ViewBag.CurrentBranchId = CurrentBranchId;
        return View("~/Views/PhReports/Report.cshtml", def);
    }

    private async Task<IActionResult> DataOf(PhRptQuery q)
    {
        var def = Def();
        if (Validate(def, q) is { } err) return Json(new { success = false, message = err });
        try
        {
            var r = await RunAsync(def, q, Math.Clamp(q.PageSize, 10, 200));
            return Json(new { success = true, tiles = r.Tiles, rows = r.Rows, totals = r.Totals, totalRows = r.TotalRows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Pharmacy report {Report} failed", def.Code);
            return Json(new { success = false, message = "The report could not be loaded: " + ex.Message });
        }
    }

    private async Task<IActionResult> ExportOf(string format, PhRptQuery q)
    {
        var def = Def();
        var pdf = string.Equals(format, "pdf", StringComparison.OrdinalIgnoreCase);
        if (!pdf && !string.Equals(format, "excel", StringComparison.OrdinalIgnoreCase)) return BadRequest("Choose Excel or PDF.");
        if (Validate(def, q) is { } err) return BadRequest(err);
        PhRptResult r;
        try { r = await RunAsync(def, q, 0); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Pharmacy report export {Report} failed", def.Code);
            return StatusCode(StatusCodes.Status502BadGateway, "The report could not be exported: " + ex.Message);
        }

        var (from, to) = Dates(def, q);
        var lists = await ListsAsync(null);
        var branch = BranchOf(q);
        var branchLabel = branch == null ? "All branches"
            : branch == CurrentBranchId ? User.FindFirst("BranchName")?.Value ?? Name(lists, "branch", branch) : Name(lists, "branch", branch);
        var info = new PhRptExportInfo(branchLabel, from, to, FilterText(def, q, lists), User.GetDisplayName(), DateTime.Now);
        var name = $"Pharmacy_{def.Code}_{def.Action}_{(def.DateMode == "none" ? DateTime.Today.ToString("yyyy-MM-dd") : $"{from:yyyy-MM-dd}_to_{to:yyyy-MM-dd}")}";
        try { await audit.LogAsync("REPORT_EXPORT", $"PhReports.{def.Action}", $"{def.Code} {def.Title} exported as {(pdf ? "PDF" : "Excel")} ({r.TotalRows} rows)", User.GetUserId(), CurrentBranchId); }
        catch (Exception ex) { logger.LogWarning(ex, "Audit of pharmacy report export failed"); }
        return pdf
            ? File(PharmacyReportExport.BuildPdf(def, r, info), "application/pdf", name + ".pdf")
            : File(PharmacyReportExport.BuildExcel(def, r, info), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", name + ".xlsx");
    }

    private static (DateTime From, DateTime To) Dates(PhRptDef def, PhRptQuery q)
    {
        if (def.DateMode == "none") return (DateTime.Today, DateTime.Today);
        var from = (q.From ?? DateTime.Today).Date; var to = (q.To ?? DateTime.Today).Date;
        return to < from ? (to, from) : (from, to);
    }

    private static string? Validate(PhRptDef def, PhRptQuery q)
    {
        var (from, to) = Dates(def, q);
        return (to - from).TotalDays > 366 ? "Please select a date range of up to one year." : null;
    }

    /// <summary>The branch of the run: the Super Admin's choice (0 = all), otherwise the user's own branch.</summary>
    private int? BranchOf(PhRptQuery q) => User.IsSuperAdmin() && q.Branch.HasValue ? (q.Branch == 0 ? null : q.Branch) : CurrentBranchId;

    private async Task<PhRptResult> RunAsync(PhRptDef def, PhRptQuery q, int pageSize)
    {
        var (from, to) = Dates(def, q);
        var sets = await api.GetAsync<List<List<Dictionary<string, JsonElement>>>>($"api/pharmacy/reports/{def.Key}" + Q(
            ("companyId", CompanyId), ("branchId", BranchOf(q)), ("from", from), ("to", to), ("page", Math.Max(1, q.Page)), ("pageSize", pageSize),
            ("userId", Has(def, "user") ? q.User : null), ("mode", Has(def, "mode") ? q.Mode : null), ("kind", Has(def, "kind") ? q.Kind : null),
            ("categoryId", Has(def, "category") ? q.Category : null), ("manufacturerId", Has(def, "manufacturer") ? q.Manufacturer : null),
            ("schedule", Has(def, "schedule") ? q.Schedule : null), ("search", Has(def, "search") ? q.Search?.Trim() : null),
            ("option", Has(def, "option") ? q.Option : null), ("supplierId", Has(def, "supplier") ? q.Supplier : null), ("storeId", Has(def, "store") ? q.Store : null), ("ledgerId", Has(def, "party") ? q.Party : null)));
        static IDictionary<string, object?> Row(Dictionary<string, JsonElement> r) =>
            r.ToDictionary(kv => char.ToUpperInvariant(kv.Key[0]) + kv.Key[1..], kv => Plain(kv.Value), StringComparer.OrdinalIgnoreCase);
        var totals = sets.Count > 2 ? sets[2].Select(Row).FirstOrDefault() : null;
        totals ??= new Dictionary<string, object?>();
        return new PhRptResult(sets[0].Select(Row).FirstOrDefault() ?? new Dictionary<string, object?>(), sets[1].Select(Row).ToList(), totals,
            totals.TryGetValue("TotalRows", out var t) && t is int n ? n : 0);
    }

    private static bool Has(PhRptDef def, string filter) => def.Filters.Contains(filter);

    private static readonly string[] ListNames = ["user", "category", "manufacturer", "schedule", "mode", "reason", "branch", "supplier", "store", "party"];

    /// <summary>The filter lists (users, categories, ...) by name; empty when the API cannot give them.</summary>
    private async Task<Dictionary<string, List<(string Value, string Text)>>> ListsAsync(int? branchId)
    {
        var lists = new Dictionary<string, List<(string Value, string Text)>>();
        try
        {
            var sets = await api.GetAsync<List<List<Dictionary<string, JsonElement>>>>("api/pharmacy/reports/lookups" + Q(("companyId", CompanyId), ("branchId", branchId)));
            for (var i = 0; i < ListNames.Length && i < sets.Count; i++)
                lists[ListNames[i]] = sets[i].Select(r => (r["value"].GetString() ?? "", r["text"].GetString() ?? "")).ToList();
        }
        catch (Exception ex) { logger.LogWarning(ex, "Pharmacy report filter lists could not be loaded"); }
        return lists;
    }

    private static string Name(Dictionary<string, List<(string Value, string Text)>> lists, string list, object value) =>
        lists.TryGetValue(list, out var l) && l.FirstOrDefault(x => x.Value == value.ToString()).Text is { } t ? t : "#" + value;

    private List<string> FilterText(PhRptDef def, PhRptQuery q, Dictionary<string, List<(string Value, string Text)>> lists)
    {
        var f = new List<string>();
        if (Has(def, "user") && q.User is > 0) f.Add("User: " + Name(lists, "user", q.User));
        if (Has(def, "mode") && !string.IsNullOrEmpty(q.Mode)) f.Add("Mode: " + Name(lists, "mode", q.Mode));
        if (Has(def, "kind") && !string.IsNullOrEmpty(q.Kind)) f.Add("Customer type: " + q.Kind switch { "PATIENT" => "Patient", "CUSTOMER" => "Credit customer", _ => "Walk-in" });
        if (Has(def, "category") && q.Category is > 0) f.Add("Category: " + Name(lists, "category", q.Category));
        if (Has(def, "manufacturer") && q.Manufacturer is > 0) f.Add("Manufacturer: " + Name(lists, "manufacturer", q.Manufacturer));
        if (Has(def, "party") && q.Party is > 0) f.Add(Name(lists, "party", q.Party));
        if (Has(def, "store") && q.Store is > 0) f.Add("Store: " + Name(lists, "store", q.Store));
        if (Has(def, "supplier") && q.Supplier is > 0) f.Add("Supplier: " + Name(lists, "supplier", q.Supplier));
        if (Has(def, "schedule") && !string.IsNullOrEmpty(q.Schedule)) f.Add("Schedule " + q.Schedule);
        if (Has(def, "search") && !string.IsNullOrWhiteSpace(q.Search)) f.Add($"Search: \"{q.Search.Trim()}\"");
        if (Has(def, "option") && !string.IsNullOrEmpty(q.Option)) f.Add(def.Options.FirstOrDefault(o => o.Value == q.Option).Text ?? q.Option);
        return f;
    }
}
