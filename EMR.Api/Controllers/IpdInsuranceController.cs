using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record IpdPreAuthSaveRequest(int? PreAuthId, string? TpaRefNo, string? Diagnosis, string? TreatmentPlan, int? ExpectedDays, decimal EstimatedAmount, string? Remarks);
public record IpdPreAuthEventRequest(string EventType, DateTime? EventAt, decimal? Amount, string? RefNo, string? Remarks, int? DocumentId);
public record IpdPreAuthSplitRequest(decimal CoPayPercent, decimal Deductible, decimal NonPayable, string? Remarks, decimal? RoomRentLimit = null, decimal? IcuRentLimit = null);
public record IpdTpaChecklistRequest(int? PreAuthId, int? ClaimId, int DocTypeId, bool IsDone, string? Remarks);
public record IpdTpaDocumentRequest(int? PreAuthId, int? ClaimId, int? DocTypeId, string? Title, string FilePath, string? Remarks);
public record IpdClaimUpdateRequest(string? TpaClaimRef, string? Remarks);
public record IpdClaimSubmitRequest(DateTime? SubmittedAt, string Mode, string? SubmissionRef, string? Remarks);
public record IpdClaimEventRequest(string EventType, DateTime? EventAt, string? RefNo, string? Remarks);
public record IpdClaimSettleRequest(DateTime SettledOn, string? Mode, string? UtrNo, decimal Amount, decimal TdsAmount, decimal DisallowedAmount,
    string? DisallowReason, string? DisallowAction, string? Remarks);
public record IpdReasonOnlyRequest(string? Reason);
public record IpdWriteOffDecisionRequest(bool Approve, string? Remarks);
public record IpdTpaDocTypeRequest(int? DocTypeId, string Name, string Stage, bool IsMandatory, int SortOrder, bool IsActive);

/// <summary>
/// IPD Phase 6 - Insurance / TPA (SQLScripts/2539-2542): pre-authorisation with the IRDAI clock, the payer split figures,
/// claims (documents, submission, queries, settlements with TDS / disallowance, write-off approval), TPA ageing and
/// statement, the TPA document checklist master. Company, branch and user come from the caller's token.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdInsuranceController(IIpdProcService ipd) : ControllerBase
{
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

    private async Task<IActionResult> Run(Func<(int CompanyId, int BranchId, int UserId), Task<IActionResult>> work) =>
        Caller() is { } c ? await work(c) : BadRequest(ApiResponse.Fail("IPD needs a signed-in user with a selected branch."));

    // ── lookups and the workspace tab ─────────────────────────────────────────────────────────────────────────────
    [HttpGet("insurance/lookups")]
    public Task<IActionResult> Lookups() => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdTpa_Lookups", new { c.CompanyId }, 3)));

    [HttpGet("admissions/{id:int}/insurance")]
    public Task<IActionResult> TabData(int id) => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdTpa_Data", new { c.CompanyId, AdmissionId = id }, 5)));

    // ── pre-authorisation ─────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("admissions/{id:int}/preauth")]
    public Task<IActionResult> SavePreAuth(int id, [FromBody] IpdPreAuthSaveRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPreAuth_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.PreAuthId, r.TpaRefNo, r.Diagnosis,
            r.TreatmentPlan, r.ExpectedDays, r.EstimatedAmount, r.Remarks })));

    [HttpPost("preauth/{id:int}/event")]
    public Task<IActionResult> PreAuthEvent(int id, [FromBody] IpdPreAuthEventRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPreAuth_Event", new { c.CompanyId, c.BranchId, c.UserId, PreAuthId = id, r.EventType, r.EventAt, r.Amount, r.RefNo, r.Remarks, r.DocumentId })));

    [HttpPost("preauth/{id:int}/split")]
    public Task<IActionResult> SaveSplit(int id, [FromBody] IpdPreAuthSplitRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPreAuth_SetSplit", new { c.CompanyId, c.BranchId, c.UserId, PreAuthId = id, r.CoPayPercent, r.Deductible, r.NonPayable, r.Remarks, r.RoomRentLimit, r.IcuRentLimit })));

    [HttpGet("preauth")]
    public Task<IActionResult> PreAuthList([FromQuery] string? view, [FromQuery] int? insuranceTpaId, [FromQuery] string? search, [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate) =>
        Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdPreAuth_List", new { c.CompanyId, c.BranchId, View = view ?? "OPEN", InsuranceTpaId = insuranceTpaId,
            Search = search, FromDate = fromDate?.Date, ToDate = toDate?.Date }, 2)));

    // ── documents and checklists (pre-auth or claim) ──────────────────────────────────────────────────────────────
    [HttpPost("insurance/checklist")]
    public Task<IActionResult> Checklist([FromBody] IpdTpaChecklistRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdTpa_ChecklistSet", new { c.CompanyId, c.BranchId, c.UserId, r.PreAuthId, r.ClaimId, r.DocTypeId, r.IsDone, r.Remarks, DocumentId = (int?)null })));

    [HttpPost("admissions/{id:int}/tpa-documents")]
    public Task<IActionResult> AddDocument(int id, [FromBody] IpdTpaDocumentRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdTpa_AddDocument", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.PreAuthId, r.ClaimId, r.DocTypeId, r.Title, r.FilePath, r.Remarks })));

    // ── claims ────────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("claims")]
    public Task<IActionResult> Claims([FromQuery] string? status, [FromQuery] int? insuranceTpaId, [FromQuery] string? search, [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate) =>
        Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdClaim_List", new { c.CompanyId, c.BranchId, Status = status ?? "ACTIVE", InsuranceTpaId = insuranceTpaId,
            Search = search, FromDate = fromDate?.Date, ToDate = toDate?.Date }, 2)));

    [HttpGet("claims/{id:int}")]
    public Task<IActionResult> Claim(int id) => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdClaim_Get", new { c.CompanyId, ClaimId = id }, 5)));

    [HttpPost("claims/{id:int}/update")]
    public Task<IActionResult> UpdateClaim(int id, [FromBody] IpdClaimUpdateRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_Update", new { c.CompanyId, c.BranchId, c.UserId, ClaimId = id, r.TpaClaimRef, r.Remarks })));

    [HttpPost("claims/{id:int}/submit")]
    public Task<IActionResult> Submit(int id, [FromBody] IpdClaimSubmitRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_Submit", new { c.CompanyId, c.BranchId, c.UserId, ClaimId = id, r.SubmittedAt, r.Mode, r.SubmissionRef, r.Remarks })));

    [HttpPost("claims/{id:int}/event")]
    public Task<IActionResult> ClaimEvent(int id, [FromBody] IpdClaimEventRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_Event", new { c.CompanyId, c.BranchId, c.UserId, ClaimId = id, r.EventType, r.EventAt, r.RefNo, r.Remarks })));

    [HttpPost("claims/{id:int}/settle")]
    public Task<IActionResult> Settle(int id, [FromBody] IpdClaimSettleRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_Settle", new { c.CompanyId, c.BranchId, c.UserId, ClaimId = id, SettledOn = r.SettledOn.Date, r.Mode, r.UtrNo,
            r.Amount, r.TdsAmount, r.DisallowedAmount, r.DisallowReason, r.DisallowAction, r.Remarks })));

    [HttpPost("claim-settlements/{id:int}/cancel")]
    public Task<IActionResult> CancelSettlement(int id, [FromBody] IpdReasonOnlyRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_SettlementCancel", new { c.CompanyId, c.BranchId, c.UserId, SettlementId = id, r.Reason })));

    [HttpPost("claim-writeoffs/{id:int}/decide")]
    public Task<IActionResult> DecideWriteOff(int id, [FromBody] IpdWriteOffDecisionRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClaim_WriteOffDecide", new { c.CompanyId, c.BranchId, c.UserId, WriteOffId = id, r.Approve, r.Remarks })));

    // ── TPA receivable ────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("tpa/ageing")]
    public Task<IActionResult> Ageing([FromQuery] DateTime? asOf, [FromQuery] int? insuranceTpaId, [FromQuery] string? basis) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdTpa_Ageing", new { c.CompanyId, c.BranchId, AsOf = asOf?.Date, InsuranceTpaId = insuranceTpaId, Basis = basis == "SUBMIT" ? "SUBMIT" : "BILL" }, 2)));

    [HttpGet("tpa/{id:int}/statement")]
    public Task<IActionResult> Statement(int id, [FromQuery] DateTime fromDate, [FromQuery] DateTime toDate) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdTpa_Statement", new { c.CompanyId, c.BranchId, InsuranceTpaId = id, FromDate = fromDate.Date, ToDate = toDate.Date }, 2)));

    // ── Master > IPD Master > TPA Document Checklist ──────────────────────────────────────────────────────────────
    [HttpGet("tpa-doctypes")]
    public Task<IActionResult> DocTypes() => Run(async c => Rows(await ipd.RowsAsync("dbo.usp_Api_IpdTpaDocType_List", new { c.CompanyId })));

    [HttpPost("tpa-doctypes")]
    public Task<IActionResult> SaveDocType([FromBody] IpdTpaDocTypeRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdTpaDocType_Save", new { c.CompanyId, c.UserId, r.DocTypeId, r.Name, r.Stage, r.IsMandatory, r.SortOrder, r.IsActive })));
}
