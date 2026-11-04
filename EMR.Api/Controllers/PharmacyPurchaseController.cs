using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Pharmacy > Purchase (SQLScripts/2358): indent, purchase order, GRN, purchase return, supplier payments, register.</summary>
[ApiController]
[Route("api/pharmacy/purchase")]
[Produces("application/json")]
public class PharmacyPurchaseController(IPharmacyPurchaseService service) : ControllerBase
{
    private static readonly HashSet<string> Kinds = ["indent", "po", "grn", "return", "payment"];
    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    private IActionResult Result(PhResult r) => Ok(ApiResponse<PhResult>.Ok(r));
    private IActionResult Doc(PhDocResult d) => Ok(ApiResponse<PhDocResult>.Ok(d));
    private IActionResult UnknownKind() => NotFound(ApiResponse<object>.Fail("Unknown purchase document."));

    // ── lookups and settings ───────────────────────────────────────────────────────────────────────────
    [HttpGet("item-search")]
    public async Task<IActionResult> ItemSearch([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string q, [FromQuery] int take = 15) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_ItemSearch", new { CompanyId = companyId, BranchId = branchId, Q = q ?? "", Take = take }));

    [HttpGet("reorder")]
    public async Task<IActionResult> Reorder([FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_ReorderSuggest", new { CompanyId = companyId, BranchId = branchId }));

    // SQLScripts/2403: sales-based Auto Reorder (settings, suggestions) and one draft PO per supplier
    [HttpGet("auto-reorder")]
    public async Task<IActionResult> AutoReorder([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int? supplierId, [FromQuery] int? categoryId, [FromQuery] bool showAll = false) =>
        Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(await service.SetsAsync("dbo.usp_Api_PhReorder_Suggest",
            new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId, CategoryId = categoryId, ShowAll = showAll }, 2)));

    [HttpPost("auto-reorder/create-pos")]
    public async Task<IActionResult> AutoReorderCreatePos([FromBody] PhAutoReorderCreateRequest req) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhReorder_CreatePos", new { req.CompanyId, req.BranchId, req.UserId, req.Lines }));

    [HttpGet("scheme-free")]
    public async Task<IActionResult> SchemeFree([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int supplierId, [FromQuery] int itemId, [FromQuery] decimal qty, [FromQuery] DateTime? onDate) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_SchemeFree", new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId, ItemId = itemId, Qty = qty, OnDate = onDate }));

    [HttpGet("suppliers")]
    public async Task<IActionResult> Suppliers([FromQuery] int companyId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_Suppliers", new { CompanyId = companyId }));

    [HttpGet("reasons")]
    public async Task<IActionResult> Reasons([FromQuery] int companyId, [FromQuery] string type) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_Reasons", new { CompanyId = companyId, Type = type }));

    [HttpGet("settings/{branchId:int}")]
    public async Task<IActionResult> Settings(int branchId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_Settings", new { BranchId = branchId }));

    [HttpGet("branch-header/{branchId:int}")]
    public async Task<IActionResult> BranchHeader(int branchId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_Ph_BranchHeader", new { BranchId = branchId }));

    [HttpGet("supplier-info")]
    public async Task<IActionResult> SupplierInfo([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int supplierId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_SupplierInfo", new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId }));

    [HttpGet("open-pos")]
    public async Task<IActionResult> OpenPos([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int supplierId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_OpenPos", new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId }));

    [HttpGet("rate-history")]
    public async Task<IActionResult> RateHistory([FromQuery] int companyId, [FromQuery] int itemId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPur_RateHistory", new { CompanyId = companyId, ItemId = itemId }));

    // ── documents ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("status-counts/{kind}")]
    public async Task<IActionResult> StatusCounts(string kind, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Kinds.Contains(kind) ? Rows(await service.RowsAsync("dbo.usp_Api_PhPur_StatusCounts", new { Kind = kind, CompanyId = companyId, BranchId = branchId })) : UnknownKind();

    [HttpGet("list/{kind}")]
    public async Task<IActionResult> List(string kind, [FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to) =>
        Kinds.Contains(kind)
            ? Rows(await service.RowsAsync("dbo.usp_Api_PhPur_List", new { Kind = kind, CompanyId = companyId, BranchId = branchId, Status = status, Search = search, From = from, To = to }))
            : UnknownKind();

    [HttpGet("doc/{kind}/{id:int}")]
    public async Task<IActionResult> Get(string kind, int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Kinds.Contains(kind) ? Doc(await service.DocAsync("dbo.usp_Api_PhPur_Get", new { Kind = kind, CompanyId = companyId, BranchId = branchId, Id = id }, true)) : UnknownKind();

    [HttpPost("delete-draft/{kind}")]
    public async Task<IActionResult> DeleteDraft(string kind, [FromBody] PhDocRefRequest req) =>
        kind is "grn" or "return"
            ? Result(await service.ResultAsync("dbo.usp_Api_PhPur_DeleteDraft", new { Kind = kind, req.CompanyId, req.BranchId, req.Id }))
            : UnknownKind();

    [HttpPost("post/{kind}")]
    public async Task<IActionResult> Post(string kind, [FromBody] PhDocRefRequest req) =>
        kind is "grn" or "return" ? Result(await service.PostAsync(kind, req)) : UnknownKind();

    // ── indent ─────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("indent/save")]
    public async Task<IActionResult> SaveIndent([FromBody] PhIndentSaveRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhIndent_Save", new { r.Id, r.CompanyId, r.BranchId, r.UserId, DocDate = r.DocDate.Date, r.Priority, r.Remarks, r.Lines, r.SupplierId }));

    [HttpPost("indent/action")]
    public async Task<IActionResult> IndentAction([FromBody] PhDocActionRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhIndent_Action", new { r.Id, r.CompanyId, r.BranchId, r.UserId, r.Action, r.Remarks }));

    // ── purchase order ─────────────────────────────────────────────────────────────────────────────────
    [HttpGet("po/indent-lines")]
    public async Task<IActionResult> IndentLines([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int indentId) =>
        Doc(await service.DocAsync("dbo.usp_Api_PhPo_IndentLines", new { CompanyId = companyId, BranchId = branchId, IndentId = indentId }, false));

    [HttpGet("po/mode")]
    public async Task<IActionResult> PoMode([FromQuery] int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPo_Mode", new { Id = id, CompanyId = companyId, BranchId = branchId }));

    [HttpPost("po/save")]
    public async Task<IActionResult> SavePo([FromBody] PhPoSaveRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhPo_Save", new
        {
            r.Id, r.CompanyId, r.BranchId, r.UserId, DocDate = r.DocDate.Date, r.SupplierId, r.IndentId, ExpectedDate = r.ExpectedDate?.Date, r.IsInterState, r.Terms, r.Remarks,
            r.Taxable, r.Gst, r.Net, r.IsDirect, r.InvoiceNo, InvoiceDate = r.InvoiceDate?.Date, r.InvoiceAmount, r.OtherCharges, r.Lines
        }));

    [HttpPost("po/action")]
    public async Task<IActionResult> PoAction([FromBody] PhDocActionRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhPo_Action", new { r.Id, r.CompanyId, r.BranchId, r.UserId, r.Action }));

    [HttpPost("po/undo-direct")]
    public async Task<IActionResult> UndoDirect([FromBody] PhPoUndoDirectRequest r)
    {
        await service.ExecAsync("dbo.usp_Api_PhPo_UndoDirectApprove", new { r.PoId, r.GrnId });
        return Ok(ApiResponse.Ok());
    }

    // SQLScripts/2413: indent e-mailed to the supplier
    [HttpPost("indent/emailed")]
    public async Task<IActionResult> IndentEmailed([FromBody] PhIndentEmailedRequest r)
    {
        await service.ExecAsync("dbo.usp_Api_PhIndent_MarkEmailed", new { r.IndentId, r.Email });
        return Ok(ApiResponse.Ok());
    }

    [HttpPost("po/emailed")]
    public async Task<IActionResult> Emailed([FromBody] PhPoEmailedRequest r)
    {
        await service.ExecAsync("dbo.usp_Api_PhPo_MarkEmailed", new { r.PoId, r.Email });
        return Ok(ApiResponse.Ok());
    }

    // ── GRN ────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("grn/po-lines")]
    public async Task<IActionResult> PoLines([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int poId) =>
        Doc(await service.DocAsync("dbo.usp_Api_PhGrn_PoLines", new { CompanyId = companyId, BranchId = branchId, PoId = poId }, false));

    [HttpPost("grn/save")]
    public async Task<IActionResult> SaveGrn([FromBody] PhGrnSaveRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhGrn_Save", new
        {
            r.Id, r.CompanyId, r.BranchId, r.UserId, DocDate = r.DocDate.Date, r.SupplierId, r.PoId, r.InvoiceNo, InvoiceDate = r.InvoiceDate.Date, r.InvoiceAmount,
            r.IsInterState, r.OtherCharges, r.Remarks, r.Lines, r.StoreId
        }));

    [HttpGet("grn/last-mrps")]
    public async Task<IActionResult> LastMrps([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int grnId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhGrn_LastMrps", new { CompanyId = companyId, BranchId = branchId, GrnId = grnId }));

    [HttpPost("grn/attach")]
    public async Task<IActionResult> Attach([FromBody] PhGrnAttachRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhGrn_Attach", new { r.CompanyId, r.BranchId, r.GrnId, r.Path, r.Name }));

    // ── purchase return ────────────────────────────────────────────────────────────────────────────────
    [HttpGet("return/batches")]
    public async Task<IActionResult> Batches([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string q, [FromQuery] int? supplierId, [FromQuery] int? storeId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhPurRet_BatchSearch", new { CompanyId = companyId, BranchId = branchId, Q = q ?? "", SupplierId = supplierId, StoreId = storeId }));

    [HttpPost("return/save")]
    public async Task<IActionResult> SaveReturn([FromBody] PhPurchaseReturnSaveRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhPurRet_Save", new
        {
            r.Id, r.CompanyId, r.BranchId, r.UserId, DocDate = r.DocDate.Date, r.SupplierId, r.ReasonId, r.IsInterState, r.Remarks, r.Lines, r.StoreId
        }));

    // ── supplier payments ──────────────────────────────────────────────────────────────────────────────
    [HttpGet("payments/balances")]
    public async Task<IActionResult> Balances([FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhSupPay_Balances", new { CompanyId = companyId, BranchId = branchId }));

    [HttpGet("payments/payables")]
    public async Task<IActionResult> Payables([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int supplierId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhSupPay_Payables", new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId }));

    [HttpPost("payments/save")]
    public async Task<IActionResult> SavePayment([FromBody] PhSupplierPaymentSaveRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhSupPay_Save", new
        {
            r.CompanyId, r.BranchId, r.UserId, r.SupplierId, Date = r.Date.Date, r.Mode, r.Reference, r.Remarks, r.Alloc, r.Adjust
        }));

    // the supplier's open debit notes, for adjustment at payment (SQLScripts/2400)
    [HttpGet("payments/debitnotes")]
    public async Task<IActionResult> DebitNotes([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int supplierId) =>
        Rows(await service.RowsAsync("dbo.usp_Api_PhSupPay_DebitNotes", new { CompanyId = companyId, BranchId = branchId, SupplierId = supplierId }));

    [HttpPost("payments/cancel")]
    public async Task<IActionResult> CancelPayment([FromBody] PhDocRefRequest r) =>
        Result(await service.ResultAsync("dbo.usp_Api_PhSupPay_Cancel", new { r.CompanyId, r.BranchId, r.Id, r.UserId }));

    // ── purchase register ──────────────────────────────────────────────────────────────────────────────
    [HttpGet("register")]
    public async Task<IActionResult> Register([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] int? supplierId,
        [FromQuery] string? docType = null, [FromQuery] string? search = null)
    {
        // SQLScripts/2399: documents, GST rate-wise summary, supplier-wise summary
        var sets = await service.SetsAsync("dbo.usp_Api_PhPur_Register", new
        {
            CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date, SupplierId = supplierId,
            DocType = docType is "PURCHASE" or "RETURN" ? docType : "ALL",
            Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim()[..Math.Min(search.Trim().Length, 100)]
        }, 3);
        return Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));
    }
}
