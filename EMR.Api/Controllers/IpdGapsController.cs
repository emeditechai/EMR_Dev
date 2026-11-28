using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record IpdBillAdjRequest(string Kind, string Lines, string? Reason);
public record IpdAllergyRequest(string? Allergies, bool NoKnownAllergy);
public record IpdCodeStatusRequest(string CodeStatus, int? DoctorId, string? DiscussedWith, string? Relation, string? Reason, string? Limits);
public record IpdIsolationRequest(string? IsolationType, string? Reason);
public record IpdVerifyRequest(string? Action, string? Note);
public record IpdEscalationRequest(string Action, int? EscalationId, string? Text);
public record IpdMedReconRequest(string Stage, bool NoHomeMeds, string? Lines, string? Source, string? Notes);
public record IpdTransfusionRequest(string Action, int? TransfusionId, string? Component, int? Units, string? Indication, int? DoctorId, string? ConsentBy,
    string? ConsentRelation, string? PatientBloodGroup, string? BagNo, string? BagBloodGroup, DateTime? BagExpiry, string? CrossmatchNo, string? CheckedBy2Name,
    string? Vitals, int? VolumeMl, string? ReactionType, string? ReactionAction, string? Reason);
public record IpdRestraintRequest(string Action, int? RestraintId, string? Kind, string? Device, string? Reason, string? AlternativesTried, int? DoctorId,
    string? FamilyInformed, bool? CirculationOk, bool? SkinOk, bool? NeedsMet, bool? StillNeeded, string? Notes);
public record IpdNewbornRequest(string? MotherIpNo, DateTime? BirthAt, decimal? BirthWeightKg, string? DeliveryType, int? GestationWeeks, byte? Apgar1, byte? Apgar5,
    byte? BabyOrder, string? Remarks);

/// <summary>
/// IPD flow-gap fixes (SQLScripts/2570-2576): interim bill, credit dues, supplementary bill / credit note, reopen a gate pass,
/// allergy / code status / isolation, medicine alerts and pharmacist verification, escalations, medication reconciliation,
/// record gaps, transfusion, restraint, newborn link. Company, branch and user come from the token.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdGapsController(IIpdProcService ipd) : ControllerBase
{
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));
    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
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

    // ── billing ────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/interim-bill")]
    public Task<IActionResult> InterimBill(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBill_Interim", new { c.CompanyId, c.BranchId, AdmissionId = id, c.UserId }, 5)));

    [HttpGet("credit-dues")]
    public Task<IActionResult> CreditDues([FromQuery] string? search) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdCreditDues_List", new { c.CompanyId, c.BranchId, Search = search })));

    [HttpGet("admissions/{id:int}/bill-adjustments")]
    public Task<IActionResult> BillAdjustments(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBillAdj_List", new { c.CompanyId, AdmissionId = id }, 3)));

    [HttpPost("admissions/{id:int}/bill-adjustments")]
    public Task<IActionResult> SaveBillAdjustment(int id, [FromBody] IpdBillAdjRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBillAdj_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Kind, r.Lines, r.Reason })));

    [HttpPost("bill-adjustments/{adjId:int}/cancel")]
    public Task<IActionResult> CancelBillAdjustment(int adjId, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBillAdj_Cancel", new { c.CompanyId, c.BranchId, c.UserId, AdjId = adjId, r.Reason })));

    [HttpGet("bill-adjustments/{adjId:int}")]
    public Task<IActionResult> BillAdjustment(int adjId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBillAdj_Get", new { c.CompanyId, AdjId = adjId }, 3)));

    [HttpPost("admissions/{id:int}/discharge/reopen")]
    public Task<IActionResult> ReopenDischarge(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_Reopen", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Reason })));

    // ── safety ─────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/med-check")]
    public Task<IActionResult> MedCheck(int id, [FromQuery] int? itemId, [FromQuery] string? drugName) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOrder_MedCheck", new { c.CompanyId, c.BranchId, AdmissionId = id, ItemId = itemId, DrugName = drugName }, 2)));

    [HttpPost("admissions/{id:int}/allergy")]
    public Task<IActionResult> SaveAllergy(int id, [FromBody] IpdAllergyRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAllergy_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Allergies, r.NoKnownAllergy })));

    [HttpGet("admissions/{id:int}/code-status")]
    public Task<IActionResult> CodeStatus(int id) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdCodeStatus_History", new { c.CompanyId, AdmissionId = id })));

    [HttpPost("admissions/{id:int}/code-status")]
    public Task<IActionResult> SaveCodeStatus(int id, [FromBody] IpdCodeStatusRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdCodeStatus_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.CodeStatus, r.DoctorId, r.DiscussedWith, r.Relation, r.Reason, r.Limits
        })));

    [HttpPost("admissions/{id:int}/isolation")]
    public Task<IActionResult> SaveIsolation(int id, [FromBody] IpdIsolationRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIsolation_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.IsolationType, r.Reason })));

    // ── clinical ───────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("orders/{orderId:int}/verify")]
    public Task<IActionResult> VerifyOrder(int orderId, [FromBody] IpdVerifyRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOrder_Verify", new { c.CompanyId, c.BranchId, c.UserId, OrderId = orderId, Action = r.Action ?? "VERIFY", r.Note })));

    [HttpGet("orders/verify-queue")]
    public Task<IActionResult> VerifyQueue([FromQuery] int? admissionId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdOrder_VerifyQueue", new { c.CompanyId, c.BranchId, AdmissionId = admissionId })));

    [HttpGet("admissions/{id:int}/escalations")]
    public Task<IActionResult> Escalations(int id) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdEscalation_List", new { c.CompanyId, c.BranchId, AdmissionId = (int?)id })));

    [HttpGet("escalations")]
    public Task<IActionResult> OpenEscalations() => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdEscalation_List", new { c.CompanyId, c.BranchId, AdmissionId = (int?)null })));

    [HttpPost("admissions/{id:int}/escalations")]
    public Task<IActionResult> EscalationAction(int id, [FromBody] IpdEscalationRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdEscalation_Action", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Action, r.EscalationId, r.Text })));

    [HttpGet("admissions/{id:int}/med-recon")]
    public Task<IActionResult> MedRecon(int id) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdMedRecon_List", new { c.CompanyId, AdmissionId = id })));

    [HttpPost("admissions/{id:int}/med-recon")]
    public Task<IActionResult> SaveMedRecon(int id, [FromBody] IpdMedReconRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdMedRecon_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Stage, r.NoHomeMeds, r.Lines, r.Source, r.Notes })));

    [HttpGet("admissions/{id:int}/record-gaps")]
    public Task<IActionResult> RecordGaps(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdRecordGaps", new { c.CompanyId, AdmissionId = id }, 2)));

    // ── transfusion, restraint, newborn ────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/safety")]
    public Task<IActionResult> Safety(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdSafety_Data", new { c.CompanyId, AdmissionId = id }, 5)));

    [HttpPost("admissions/{id:int}/transfusion")]
    public Task<IActionResult> SaveTransfusion(int id, [FromBody] IpdTransfusionRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdTransfusion_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Action, r.TransfusionId, r.Component, r.Units, r.Indication, r.DoctorId, r.ConsentBy, r.ConsentRelation,
            r.PatientBloodGroup, r.BagNo, r.BagBloodGroup, BagExpiry = r.BagExpiry?.Date, r.CrossmatchNo, r.CheckedBy2Name, r.Vitals, r.VolumeMl, r.ReactionType, r.ReactionAction, r.Reason
        })));

    [HttpPost("admissions/{id:int}/restraint")]
    public Task<IActionResult> SaveRestraint(int id, [FromBody] IpdRestraintRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdRestraint_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Action, r.RestraintId, r.Kind, r.Device, r.Reason, r.AlternativesTried, r.DoctorId, r.FamilyInformed,
            r.CirculationOk, r.SkinOk, r.NeedsMet, r.StillNeeded, r.Notes
        })));

    [HttpPost("admissions/{id:int}/newborn")]
    public Task<IActionResult> LinkNewborn(int id, [FromBody] IpdNewbornRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdNewborn_Link", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.MotherIpNo, r.BirthAt, r.BirthWeightKg, r.DeliveryType, r.GestationWeeks, r.Apgar1, r.Apgar5,
            BabyOrder = r.BabyOrder ?? 1, r.Remarks
        })));
}
