using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record IpdDischargeAdviseRequest(string DischargeType, int AdvisedByDoctorId, DateTime? PlannedAt, string? Remarks, string? TransferTo);
public record IpdDischargeClearRequest(string Dept, string? Action, string? Checklist, string? Remarks);
public record IpdDischargeSummaryRequest(string? Diagnoses, string? PresentingComplaints, string? HistoryOfIllness, string? PastHistory, string? Allergies,
    string? Examination, string? Investigations, string? Procedures, string? CourseInHospital, string? ConditionAtDischarge, string? ConditionNotes,
    string? Medicines, string? Diet, string? Activity, string? Advice, string? WarningSigns, string? FollowUp, string? EmergencyContact,
    bool Sign, bool CanSign, int? SignedByDoctorId, string? AmendReason, bool CanSignOnBehalf = false, string? OnBehalfReason = null);
public record IpdDischargeLamaRequest(string? Reason, string? RisksExplained, int? ExplainedByDoctorId, string? SignedByName, string? SignedByRelation,
    string? SignaturePath, string? WitnessName, string? WitnessSignaturePath, string? DoctorSignaturePath, string? VoidReason);
public record IpdDischargeDeathRequest(DateTime? DeathAt, string? FormType, string? CauseImmediate, string? IntervalImmediate, string? CauseAntecedent,
    string? IntervalAntecedent, string? CauseUnderlying, string? IntervalUnderlying, string? UnderlyingIcd, string? OtherConditions, string? MannerOfDeath,
    string? PregnancyStatus, bool DeliveryInvolved, bool PoliceIntimated, string? PoliceStation, bool PostMortem, int? CertifiedByDoctorId,
    string? BodyHandedTo, string? BodyHandedRelation, DateTime? BodyHandedAt, string? Remarks, string? VoidReason);
public record IpdGatePassRequest(string? HandedOverTo, string? HandedOverRelation, string? HandedOverPhone, string? TransportMode, string? Remarks,
    bool Credit, string? CreditReason, bool CanCredit, bool CanStaleBill = false, string? StaleBillReason = null);
public record IpdFollowUpLinkRequest(int OpdServiceId, int? FollowUpId);
public record IpdFollowUpRequest(int? FollowUpId, int? DoctorId, DateTime? FollowUpDate, int? ScheduleId, string? SlotTime, string? Notes, string? CancelReason);

/// <summary>
/// IPD Phase 7 (SQLScripts/2557-2558): discharge advice, clearances, discharge / death summary, LAMA / DAMA form, death record,
/// gate pass with bed release, OPD follow-up, prints and the Discharges board. Company, branch and user come from the token.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdDischargeController(IIpdProcService ipd) : ControllerBase
{
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

    [HttpGet("admissions/{id:int}/discharge")]
    public Task<IActionResult> Data(int id) => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdDischarge_Data", new { c.CompanyId, c.BranchId, AdmissionId = id, c.UserId }, 9)));

    [HttpGet("admissions/{id:int}/discharge/prefill")]
    public Task<IActionResult> Prefill(int id) => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdDischarge_Prefill", new { c.CompanyId, c.BranchId, AdmissionId = id }, 4)));

    [HttpGet("admissions/{id:int}/discharge/print")]
    public Task<IActionResult> Print(int id, [FromQuery] int? summaryId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdDischarge_Print", new { c.CompanyId, c.BranchId, AdmissionId = id, SummaryId = summaryId }, 7)));

    /// <summary>Medicines on discharge: Master > EMR Medication of the company.</summary>
    [HttpGet("discharge/medicines")]
    public Task<IActionResult> Medicines([FromQuery] string? q) => Run(async c =>
        Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await ipd.RowsAsync("dbo.usp_Api_IpdDischarge_Medicines", new { c.CompanyId, Q = q, Top = 20 }))));

    [HttpGet("discharges")]
    public Task<IActionResult> Board([FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] string? type, [FromQuery] string? search) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdDischarge_Board", new { c.CompanyId, c.BranchId, FromDate = from?.Date, ToDate = to?.Date, DischargeType = string.IsNullOrWhiteSpace(type) ? null : type, Search = search }, 4)));

    [HttpPost("admissions/{id:int}/discharge/advise")]
    public Task<IActionResult> Advise(int id, [FromBody] IpdDischargeAdviseRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_Advise", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.DischargeType, r.AdvisedByDoctorId, r.PlannedAt, r.Remarks, r.TransferTo })));

    [HttpPost("admissions/{id:int}/discharge/cancel")]
    public Task<IActionResult> CancelAdvice(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_CancelAdvice", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Reason })));

    [HttpPost("admissions/{id:int}/discharge/clear")]
    public Task<IActionResult> Clear(int id, [FromBody] IpdDischargeClearRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_Clear", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Dept, Action = r.Action ?? "CLEAR", r.Checklist, r.Remarks })));

    [HttpPost("admissions/{id:int}/discharge/summary")]
    public Task<IActionResult> Summary(int id, [FromBody] IpdDischargeSummaryRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischargeSummary_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Diagnoses, r.PresentingComplaints, r.HistoryOfIllness, r.PastHistory, r.Allergies, r.Examination,
            r.Investigations, r.Procedures, r.CourseInHospital, r.ConditionAtDischarge, r.ConditionNotes, r.Medicines, r.Diet, r.Activity, r.Advice, r.WarningSigns,
            r.FollowUp, r.EmergencyContact, r.Sign, r.CanSign, r.SignedByDoctorId, r.AmendReason, r.CanSignOnBehalf, r.OnBehalfReason
        })));

    [HttpPost("admissions/{id:int}/discharge/lama")]
    public Task<IActionResult> Lama(int id, [FromBody] IpdDischargeLamaRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_Lama", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Reason, r.RisksExplained, r.ExplainedByDoctorId, r.SignedByName, r.SignedByRelation,
            r.SignaturePath, r.WitnessName, r.WitnessSignaturePath, r.DoctorSignaturePath, r.VoidReason
        })));

    [HttpPost("admissions/{id:int}/discharge/death")]
    public Task<IActionResult> Death(int id, [FromBody] IpdDischargeDeathRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_Death", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.DeathAt, r.FormType, r.CauseImmediate, r.IntervalImmediate, r.CauseAntecedent, r.IntervalAntecedent,
            r.CauseUnderlying, r.IntervalUnderlying, r.UnderlyingIcd, r.OtherConditions, r.MannerOfDeath, r.PregnancyStatus, r.DeliveryInvolved, r.PoliceIntimated,
            r.PoliceStation, r.PostMortem, r.CertifiedByDoctorId, r.BodyHandedTo, r.BodyHandedRelation, r.BodyHandedAt, r.Remarks, r.VoidReason
        })));

    [HttpPost("admissions/{id:int}/discharge/gatepass")]
    public Task<IActionResult> GatePass(int id, [FromBody] IpdGatePassRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_GatePass", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.HandedOverTo, r.HandedOverRelation, r.HandedOverPhone, r.TransportMode, r.Remarks,
            r.Credit, r.CreditReason, r.CanCredit, r.CanStaleBill, r.StaleBillReason
        })));

    /// <summary>Booked IPD follow-ups of a patient (OPD New Service Booking shows them; SQLScripts/2560).</summary>
    [HttpGet("followups/patient/{patientId:int}")]
    public Task<IActionResult> FollowUpsForPatient(int patientId) => Run(async c =>
        Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await ipd.RowsAsync("dbo.usp_Api_IpdFollowUp_ForPatient", new { c.CompanyId, c.BranchId, PatientId = patientId }))));

    /// <summary>An OPD booking closes the patient's follow-up (the one given, or the booked one with that doctor near the visit date).</summary>
    [HttpPost("followups/link-opd")]
    public Task<IActionResult> LinkOpd([FromBody] IpdFollowUpLinkRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdFollowUp_LinkOpd", new { c.CompanyId, c.BranchId, c.UserId, r.OpdServiceId, r.FollowUpId })));

    [HttpPost("admissions/{id:int}/discharge/followup")]
    public Task<IActionResult> FollowUp(int id, [FromBody] IpdFollowUpRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDischarge_FollowUp", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.FollowUpId, r.DoctorId, FollowUpDate = r.FollowUpDate?.Date, r.ScheduleId, r.SlotTime, r.Notes, r.CancelReason
        })));
}
