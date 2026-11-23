using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record PhInvTransferRequestSave(int Id, int CompanyId, int BranchId, int UserId, int FromBranchId, string? Priority, string? Remarks, bool Submit, string Lines);
public record PhInvDispatchRequest(int CompanyId, int BranchId, int UserId, int Id, string? Remarks, string Lines, int? StoreId = null);
public record PhInvReceiveRequest(int CompanyId, int BranchId, int UserId, int Id, string? Remarks, string Received, int? StoreId = null);
public record PhInvActionRequest(int CompanyId, int BranchId, int UserId, int Id, string? Action, string? Remarks);
public record PhInvAdjustmentSave(int Id, int CompanyId, int BranchId, int UserId, string Kind, DateTime DocDate, int ReasonId, string? Remarks, string? DisposalMethod,
    string? DisposalAgency, DateTime? DisposalDate, string? Witness1, string? Witness2, string? CertificateNo, string Lines, int? StoreId = null);
public record PhInvCountCreate(int CompanyId, int BranchId, int UserId, string? RackPrefix, int? CategoryId, bool IncludeZero, string? Remarks, int? StoreId = null);

// store issue (SQLScripts/2364)
public record PhIssueRequestSave(int Id, int CompanyId, int BranchId, int UserId, int FromStoreId, int ToStoreId, string? Remarks, bool Submit, string Lines);
public record PhIssueIssueRequest(int CompanyId, int BranchId, int UserId, int Id, string? Remarks, string Lines);
public record PhIssueReceiveRequest(int CompanyId, int BranchId, int UserId, int Id, string? Remarks, string Received);
public record PhInvCountsSave(int CompanyId, int BranchId, int Id, string Counts, int? UserId = null);
public record PhInvCorrectionSave(int CompanyId, int BranchId, int UserId, int BatchId, string NewBatchNo, DateTime NewExpiry, decimal NewMrp, string Reason);

/// <summary>Pharmacy > Inventory (SQLScripts/2360): stock, transfers, adjustments / write-offs, physical counts, batch corrections, dashboard.</summary>
[ApiController]
[Route("api/pharmacy/inventory")]
[Produces("application/json")]
public class PharmacyInventoryController(IPharmacyProcService ph) : ControllerBase
{
    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));
    private IActionResult Sets(List<List<IDictionary<string, object?>>> sets) => Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));

    // ── stock ──────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("stock")]
    public async Task<IActionResult> Stock([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? search, [FromQuery] int? categoryId, [FromQuery] string? filter,
        [FromQuery] int? storeId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Stock", new { CompanyId = companyId, BranchId = branchId, Search = search, CategoryId = categoryId, Filter = filter, StoreId = storeId }));

    [HttpGet("ledger")]
    public async Task<IActionResult> Ledger([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int itemId, [FromQuery] int? batchId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Ledger", new { CompanyId = companyId, BranchId = branchId, ItemId = itemId, BatchId = batchId }));

    [HttpGet("batch-search")]
    public async Task<IActionResult> BatchSearch([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string q, [FromQuery] bool expiredOnly = false,
        [FromQuery] int? storeId = null) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_BatchSearch", new { CompanyId = companyId, BranchId = branchId, Q = q ?? "", ExpiredOnly = expiredOnly, StoreId = storeId }));

    [HttpGet("other-branches")]
    public async Task<IActionResult> OtherBranches([FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_OtherBranches", new { CompanyId = companyId, BranchId = branchId }));

    // ── transfers ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("transfers")]
    public async Task<IActionResult> Transfers([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string dir, [FromQuery] string? status) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Transfers", new { CompanyId = companyId, BranchId = branchId, Dir = dir, Status = status }));

    [HttpGet("transfer/{id:int}")]
    public async Task<IActionResult> Transfer(int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhInv_GetTransfer", new { CompanyId = companyId, BranchId = branchId, Id = id }, 2));

    [HttpPost("transfer/save")]
    public async Task<IActionResult> SaveTransfer([FromBody] PhInvTransferRequestSave r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_SaveTransferRequest", new { r.Id, r.CompanyId, r.BranchId, r.UserId, r.FromBranchId, r.Priority, r.Remarks, r.Submit, r.Lines }));

    [HttpPost("transfer/dispatch")]
    public async Task<IActionResult> Dispatch([FromBody] PhInvDispatchRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_Dispatch", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Remarks, r.Lines, r.StoreId }));

    [HttpPost("transfer/receive")]
    public async Task<IActionResult> Receive([FromBody] PhInvReceiveRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_Receive", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Remarks, r.Received, r.StoreId }));

    [HttpPost("transfer/cancel")]
    public async Task<IActionResult> CancelTransfer([FromBody] PhInvActionRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_CancelTransfer", new { r.CompanyId, r.BranchId, r.UserId, r.Id }));

    // ── adjustments / write-offs ───────────────────────────────────────────────────────────────────────
    [HttpGet("adjustments")]
    public async Task<IActionResult> Adjustments([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string kind, [FromQuery] string? status) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Adjustments", new { CompanyId = companyId, BranchId = branchId, Kind = kind, Status = status }));

    [HttpGet("adjustment/{id:int}")]
    public async Task<IActionResult> Adjustment(int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhInv_GetAdjustment", new { CompanyId = companyId, BranchId = branchId, Id = id }, 2));

    [HttpPost("adjustment/save")]
    public async Task<IActionResult> SaveAdjustment([FromBody] PhInvAdjustmentSave r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_SaveAdjustment", new
        {
            r.Id, r.CompanyId, r.BranchId, r.UserId, r.Kind, DocDate = r.DocDate.Date, r.ReasonId, r.Remarks, r.DisposalMethod, r.DisposalAgency,
            DisposalDate = r.DisposalDate?.Date, r.Witness1, r.Witness2, r.CertificateNo, r.Lines, r.StoreId
        }));

    [HttpPost("adjustment/action")]
    public async Task<IActionResult> AdjustmentAction([FromBody] PhInvActionRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_AdjustmentAction", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Action, r.Remarks }));

    // ── physical counts ────────────────────────────────────────────────────────────────────────────────
    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Counts", new { CompanyId = companyId, BranchId = branchId }));

    [HttpGet("count/{id:int}")]
    public async Task<IActionResult> Count(int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhInv_GetCount", new { CompanyId = companyId, BranchId = branchId, Id = id }, 2));

    [HttpPost("count/create")]
    public async Task<IActionResult> CreateCount([FromBody] PhInvCountCreate r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_CreateCount", new { r.CompanyId, r.BranchId, r.UserId, r.RackPrefix, r.CategoryId, r.IncludeZero, r.Remarks, r.StoreId }));

    [HttpPost("count/save")]
    public async Task<IActionResult> SaveCounts([FromBody] PhInvCountsSave r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_SaveCounts", new { r.CompanyId, r.BranchId, r.Id, r.Counts, r.UserId }));

    // SQLScripts/2405: racks with stock, last verified, due for a cycle count
    [HttpGet("count/cycle-plan")]
    public async Task<IActionResult> CycleCountPlan([FromQuery] int companyId, [FromQuery] int branchId) =>
        Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await ph.RowsAsync("dbo.usp_Api_PhInv_CycleCountPlan", new { CompanyId = companyId, BranchId = branchId })));

    [HttpPost("count/action")]
    public async Task<IActionResult> CountAction([FromBody] PhInvActionRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_CountAction", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Action, r.Remarks }));

    // ── batch corrections ──────────────────────────────────────────────────────────────────────────────
    [HttpGet("corrections")]
    public async Task<IActionResult> Corrections([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? status) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_Corrections", new { CompanyId = companyId, BranchId = branchId, Status = status }));

    [HttpPost("correction/save")]
    public async Task<IActionResult> SaveCorrection([FromBody] PhInvCorrectionSave r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_SaveCorrection", new
        {
            r.CompanyId, r.BranchId, r.UserId, r.BatchId, r.NewBatchNo, NewExpiry = r.NewExpiry.Date, r.NewMrp, r.Reason
        }));

    [HttpPost("correction/action")]
    public async Task<IActionResult> CorrectionAction([FromBody] PhInvActionRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhInv_CorrectionAction", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Action, r.Remarks }));

    // ── approvals and dashboard ────────────────────────────────────────────────────────────────────────
    [HttpGet("maker/{table}/{id:int}")]
    public async Task<IActionResult> Maker(string table, int id) =>
        table is "adj" or "count" or "corr" ? Row(await ph.RowAsync("dbo.usp_Api_PhInv_Maker", new { Table = table, Id = id })) : NotFound(ApiResponse<object>.Fail("Unknown document."));

    [HttpGet("matrix-approvers")]
    public async Task<IActionResult> MatrixApprovers([FromQuery] int companyId, [FromQuery] string moduleCode, [FromQuery] int branchId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhInv_MatrixApprovers", new { CompanyId = companyId, ModuleCode = moduleCode, BranchId = branchId }));

    [HttpGet("dashboard")]
    public async Task<IActionResult> Dashboard([FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhInv_Dashboard", new { CompanyId = companyId, BranchId = branchId }, 9));

    // ── stores and store issue (SQLScripts/2364) ─────────────────────────────────────────────────────────
    [HttpGet("stores")]
    public async Task<IActionResult> Stores([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? purpose) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhStore_Options", new { CompanyId = companyId, BranchId = branchId, Purpose = purpose ?? "ANY" }));

    [HttpGet("store-batches")]
    public async Task<IActionResult> StoreBatches([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int storeId, [FromQuery] int itemId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhStore_Batches", new { CompanyId = companyId, BranchId = branchId, StoreId = storeId, ItemId = itemId }));

    [HttpGet("issues")]
    public async Task<IActionResult> Issues([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? status) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhIss_List", new { CompanyId = companyId, BranchId = branchId, Status = status }));

    [HttpGet("issue/{id:int}")]
    public async Task<IActionResult> Issue(int id, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhIss_Get", new { CompanyId = companyId, BranchId = branchId, Id = id }, 2));

    [HttpPost("issue/save")]
    public async Task<IActionResult> SaveIssueRequest([FromBody] PhIssueRequestSave r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhIss_SaveRequest", new { r.Id, r.CompanyId, r.BranchId, r.UserId, r.FromStoreId, r.ToStoreId, r.Remarks, r.Submit, r.Lines }));

    [HttpPost("issue/issue")]
    public async Task<IActionResult> IssueStock([FromBody] PhIssueIssueRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhIss_Issue", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Remarks, r.Lines }));

    [HttpPost("issue/receive")]
    public async Task<IActionResult> ReceiveIssue([FromBody] PhIssueReceiveRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhIss_Receive", new { r.CompanyId, r.BranchId, r.UserId, r.Id, r.Remarks, r.Received }));

    [HttpPost("issue/cancel")]
    public async Task<IActionResult> CancelIssue([FromBody] PhInvActionRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhIss_Cancel", new { r.CompanyId, r.BranchId, r.UserId, r.Id }));
}
