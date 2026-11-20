using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record QcInvDocSaveRequest(int? DocId, string DocType, DateTime? DocDate, int StoreId, int? ToStoreId, int? SupplierId, int? RefDocId,
    string? SupplierInvNo, DateTime? SupplierInvDate, DateTime? ExpectedDate, bool IsInterState, string? ReasonCode, string? Priority, string? Terms,
    decimal? OtherCharges, string? Remarks, string Lines);
public record QcInvDocActionRequest(int DocId, string DocType, string Action, string? Remarks, string? Data, bool IsSuperAdmin);
public record QcInvCountCreateRequest(int StoreId, int? CategoryId, bool IncludeZero, string? Remarks);
public record QcInvLotActionRequest(int LotId, string Action, string? Note);
public record QcInvMarkOpenedRequest(int StoreId, int LotId, DateTime? OpenedOn, bool Clear);
public record QcInvLinesRequest(string LineIds, string? Reason);
public record QcInvSettingsRequest(bool PoApprovalRequired, bool AdjApprovalRequired, bool CountApprovalRequired, bool LotAcceptanceRequired,
    bool DeductOnConsumption, int NearExpiryDays);

/// <summary>
/// Quality &amp; Compliance > Stock Management (SQLScripts/2498-2500): lab reagent / consumable stock, separate from the
/// pharmacy. Opening stock, purchase orders, goods receipts, lot acceptance, purchase returns, indents, issues / transfers,
/// adjustments, physical counts, stock enquiry, pending lab consumption, dashboard and reports.
/// Company, branch and user come from the caller's token; every rule lives in the procedures.
/// </summary>
[ApiController]
[Route("api/qc/stock")]
[Produces("application/json")]
public class QcStockController(IQcStockProcService qc, ILogger<QcStockController> logger) : ControllerBase
{
    private static readonly HashSet<string> DocTypes = new(StringComparer.OrdinalIgnoreCase) { "OPN", "PO", "GRN", "PRET", "IND", "ISS", "ADJ", "CNT" };
    private static readonly HashSet<string> Reports = new(StringComparer.OrdinalIgnoreCase)
        { "STOCK", "LOTS", "VALUATION", "MOVEMENT", "SUMMARY", "EXPIRY", "PURCHASE", "SUPPLIER", "PO", "ISSUE", "ADJUST", "CONSUMPTION", "TRACE", "FSN" };

    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));
    private IActionResult Sets(List<List<IDictionary<string, object?>>> sets) => Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));

    private (int CompanyId, int BranchId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        if (!int.TryParse(User.FindFirstValue("BranchId"), out var branchId) || branchId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, branchId, userId);
    }

    private async Task<IActionResult> Run(Func<(int CompanyId, int BranchId, int UserId), Task<IActionResult>> work)
    {
        if (Caller() is not { } c) return BadRequest(ApiResponse.Fail("Stock management needs a signed-in user with a selected branch."));
        try { return await work(c); }
        catch (QcStockRuleException ex) { return Ok(ApiResponse.Fail(ex.Message)); }
        catch (Exception ex)
        {
            logger.LogError(ex, "[QC-STOCK] {Path} failed", Request.Path);
            return StatusCode(500, ApiResponse.Fail("The stock request could not be completed. Please try again."));
        }
    }

    private static string? Type(string? docType) => docType is not null && DocTypes.Contains(docType) ? docType.ToUpperInvariant() : null;

    // ── lookups, documents ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("lookups")]
    public Task<IActionResult> Lookups() => Run(async c => Sets(await qc.SetsAsync("dbo.usp_Api_QcInv_Lookups", new { c.CompanyId, c.BranchId }, 6)));

    [HttpGet("docs")]
    public Task<IActionResult> Docs([FromQuery] string docType, [FromQuery] string? status, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string? search, [FromQuery] string? scope, [FromQuery] int? storeId) => Run(async c =>
        Type(docType) is not { } t ? BadRequest(ApiResponse.Fail("Unknown document type.")) :
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_DocList", new { c.CompanyId, c.BranchId, DocType = t, Status = status, FromDate = from?.Date, ToDate = to?.Date,
            Search = search, Scope = scope, StoreId = storeId })));

    [HttpGet("doc/{id:int}")]
    public Task<IActionResult> Doc(int id, [FromQuery] string? docType) => Run(async c =>
        Sets(await qc.SetsAsync("dbo.usp_Api_QcInv_DocGet", new { c.CompanyId, c.BranchId, DocId = id, DocType = Type(docType) }, 4)));

    [HttpPost("doc/save")]
    public Task<IActionResult> Save([FromBody] QcInvDocSaveRequest r) => Run(async c =>
        Type(r.DocType) is not { } t ? BadRequest(ApiResponse.Fail("Unknown document type.")) :
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_DocSave", new
        {
            c.CompanyId, c.BranchId, c.UserId, DocId = r.DocId is > 0 ? r.DocId : null, DocType = t, DocDate = r.DocDate?.Date, r.StoreId, r.ToStoreId, r.SupplierId,
            r.RefDocId, r.SupplierInvNo, SupplierInvDate = r.SupplierInvDate?.Date, ExpectedDate = r.ExpectedDate?.Date, r.IsInterState, r.ReasonCode, r.Priority,
            r.Terms, OtherCharges = r.OtherCharges ?? 0m, r.Remarks, r.Lines
        })));

    [HttpPost("doc/action")]
    public Task<IActionResult> Action([FromBody] QcInvDocActionRequest r) => Run(async c =>
        Type(r.DocType) is not { } t ? BadRequest(ApiResponse.Fail("Unknown document type.")) :
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_DocAction", new
            { c.CompanyId, c.BranchId, c.UserId, r.IsSuperAdmin, r.DocId, r.Action, r.Remarks, r.Data, DocType = t })));

    [HttpPost("count/create")]
    public Task<IActionResult> CountCreate([FromBody] QcInvCountCreateRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_CountCreate", new { c.CompanyId, c.BranchId, c.UserId, r.StoreId, r.CategoryId, r.IncludeZero, r.Remarks })));

    // ── stock ───────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("stock")]
    public Task<IActionResult> Stock([FromQuery] int? storeId, [FromQuery] string? view, [FromQuery] string? filter, [FromQuery] string? search,
        [FromQuery] int? categoryId) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Stock", new { c.CompanyId, c.BranchId, StoreId = storeId, View = view ?? "ITEM", Filter = filter, Search = search, CategoryId = categoryId })));

    [HttpGet("ledger")]
    public Task<IActionResult> Ledger([FromQuery] int itemId, [FromQuery] int? storeId, [FromQuery] int? lotId, [FromQuery] DateTime? from, [FromQuery] DateTime? to) => Run(async c =>
        Sets(await qc.SetsAsync("dbo.usp_Api_QcInv_ItemLedger", new { c.CompanyId, c.BranchId, ItemId = itemId, StoreId = storeId, LotId = lotId, FromDate = from?.Date, ToDate = to?.Date }, 2)));

    [HttpGet("lots-for-pick")]
    public Task<IActionResult> LotsForPick([FromQuery] int storeId, [FromQuery] int itemId, [FromQuery] string? purpose) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_LotsForPick", new { c.CompanyId, c.BranchId, StoreId = storeId, ItemId = itemId, Purpose = purpose ?? "ISSUE" })));

    [HttpGet("fefo")]
    public Task<IActionResult> Fefo([FromQuery] int storeId, [FromQuery] int itemId, [FromQuery] decimal qty) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Fefo", new { c.CompanyId, StoreId = storeId, ItemId = itemId, Qty = qty })));

    [HttpGet("indent-for-issue/{id:int}")]
    public Task<IActionResult> IndentForIssue(int id) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_IndentForIssue", new { c.CompanyId, c.BranchId, IndentId = id })));

    [HttpGet("reorder")]
    public Task<IActionResult> Reorder() => Run(async c => Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Reorder", new { c.CompanyId, c.BranchId })));

    // ── lots ────────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("lots")]
    public Task<IActionResult> Lots([FromQuery] string? status, [FromQuery] string? search) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Lots", new { c.CompanyId, c.BranchId, Status = status, Search = search })));

    [HttpPost("lot/action")]
    public Task<IActionResult> LotAction([FromBody] QcInvLotActionRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_LotAction", new { c.CompanyId, c.UserId, r.LotId, r.Action, r.Note })));

    [HttpPost("mark-opened")]
    public Task<IActionResult> MarkOpened([FromBody] QcInvMarkOpenedRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_MarkOpened", new { c.CompanyId, c.BranchId, c.UserId, r.StoreId, r.LotId, OpenedOn = r.OpenedOn?.Date, r.Clear })));

    // ── pending lab consumption ─────────────────────────────────────────────────────────────────────────────────
    [HttpGet("pending")]
    public Task<IActionResult> Pending([FromQuery] string? status, [FromQuery] DateTime? from, [FromQuery] DateTime? to) => Run(async c =>
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Pending", new { c.CompanyId, c.BranchId, Status = status, FromDate = from?.Date, ToDate = to?.Date })));

    [HttpPost("pending/retry")]
    public Task<IActionResult> PendingRetry([FromBody] QcInvLinesRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_PendingRetry", new { c.CompanyId, c.BranchId, c.UserId, r.LineIds })));

    [HttpPost("pending/skip")]
    public Task<IActionResult> PendingSkip([FromBody] QcInvLinesRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_PendingSkip", new { c.CompanyId, c.BranchId, c.UserId, r.LineIds, r.Reason })));

    // ── dashboard, settings, accounts, reports ──────────────────────────────────────────────────────────────────
    [HttpGet("dashboard")]
    public Task<IActionResult> Dashboard() => Run(async c => Sets(await qc.SetsAsync("dbo.usp_Api_QcInv_Dashboard", new { c.CompanyId, c.BranchId }, 6)));

    [HttpPost("settings")]
    public Task<IActionResult> Settings([FromBody] QcInvSettingsRequest r) => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_SettingsSave", new
            { c.CompanyId, c.UserId, r.PoApprovalRequired, r.AdjApprovalRequired, r.CountApprovalRequired, r.LotAcceptanceRequired, r.DeductOnConsumption, r.NearExpiryDays })));

    [HttpPost("post-consumption")]
    public Task<IActionResult> PostConsumption() => Run(async c =>
        Row(await qc.RowAsync("dbo.usp_Api_QcInv_PostConsumption", new { c.CompanyId, c.BranchId, c.UserId })));

    [HttpGet("report/{key}")]
    public Task<IActionResult> Report(string key, [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] int? storeId, [FromQuery] int? itemId,
        [FromQuery] int? supplierId, [FromQuery] int? categoryId, [FromQuery] int? days, [FromQuery] string? search) => Run(async c =>
        !Reports.Contains(key) ? BadRequest(ApiResponse.Fail("Unknown report.")) :
        Rows(await qc.RowsAsync("dbo.usp_Api_QcInv_Report", new
        {
            c.CompanyId, c.BranchId, Report = key.ToUpperInvariant(), FromDate = from?.Date, ToDate = to?.Date, StoreId = storeId, ItemId = itemId,
            SupplierId = supplierId, CategoryId = categoryId, Days = days, Search = search
        })));
}
