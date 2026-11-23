using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record IpdOtSaveRequest(int? OtBookingId, int OtId, int? ProcedureId, string? ProcedureName, string? Laterality, string SurgeryType, int SurgeonId,
    int? AssistantSurgeonId, int? AnaesthetistId, int? AnaesthesiaTypeId, string? ScrubNurse, string? CirculatingNurse, DateTime ScheduledStart,
    int DurationMinutes, string? PreOpDiagnosis, string? Remarks, bool IsUnplannedReturn, string? ReturnReason);
public record IpdOtChecklistRequest(string Phase, string Answers, string? Remarks);
public record IpdOtTimesRequest(DateTime? InOtAt, DateTime? AnaesStartAt, DateTime? IncisionAt, DateTime? ClosureAt, DateTime? AnaesEndAt,
    DateTime? OutOtAt, DateTime? RecoveryOutAt, bool Complete);
public record IpdOtAnaesthesiaRequest(int? AnaesthesiaTypeId, string? AsaGrade, int? Mallampati, DateTime? NpoSince, string? Airway, string? Comorbidities,
    string? PreAnaesNotes, string? Technique, string? AirwayDevice, string? Drugs, string? Monitoring, int? FluidsMl, int? BloodGivenMl, int? UrineMl,
    int? BloodLossMl, string? Complications, int? AldreteScore, string? RecoveryNotes, bool Sign);
public record IpdOtNoteRequest(string ProcedurePerformed, string? PostOpDiagnosis, string? Indication, string? Findings, string? ProcedureDetails,
    string? Specimens, bool SpecimenToHistopath, string? Drains, int? BloodLossMl, string? Complications, string? Closure, string? PostOpPlan,
    string? PatientCondition, bool Sign, bool CanSign, string? AmendReason);
public record IpdOtImplantRequest(string ItemType, int? ItemId, int? BatchId, int? StoreId, decimal Qty, string? SerialNo, string? Remarks);   // issued from pharmacy stock
public record IpdOtChargesRequest(string Lines, bool CanEditRate);
public record IpdIcuObservationRequest(DateTime ObservedAt, short? Hr, short? Sbp, short? Dbp, short? Rr, decimal? SpO2, decimal? TempC, short? Cvp,
    short? EtCo2, byte? GcsE, byte? GcsV, byte? GcsM, short? Rass, byte? PainScore, decimal? Glucose, int? IntakeMl, int? UrineMl, int? OtherOutputMl,
    string? VentMode, byte? FiO2, decimal? Peep, short? TidalVolume, short? SetRate, short? Pip, short? PressureSupport, string? Notes);
public record IpdIcuStrikeRequest(string Kind, long Id, string? Reason);
public record IpdIcuInfusionRequest(int? InfusionId, string? EventType, string? Drug, string? Concentration, decimal? RateMlHr, string? Dose,
    string? Route, DateTime? EventAt, string? Remarks);
public record IpdIcuDeviceRequest(int? DeviceId, string? HeadCode, string? HeadName, DateTime? At, string? Remarks);

/// <summary>
/// IPD Phase 8 (SQLScripts/2492-2494): OT booking, checklists, anaesthesia record, surgery note, implants and OT charges;
/// ICU flowsheet, infusions, device use and the ICU board. Company, branch and user come from the caller's token.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdOtIcuController(IIpdProcService ipd) : ControllerBase
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

    // ── OT ──────────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("ot/lookups")]
    public Task<IActionResult> OtLookups() => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOt_Lookups", new { c.CompanyId, c.BranchId }, 6)));

    [HttpGet("ot/schedule")]
    public Task<IActionResult> OtSchedule([FromQuery] DateTime? date, [FromQuery] int? otId, [FromQuery] bool includeCancelled = false) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOt_Schedule", new { c.CompanyId, c.BranchId, Date = (date ?? DateTime.Today).Date, OtId = otId, IncludeCancelled = includeCancelled }, 2)));

    [HttpGet("admissions/{id:int}/ot")]
    public Task<IActionResult> OtData(int id) => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOt_Data", new { c.CompanyId, c.BranchId, AdmissionId = id }, 7)));

    [HttpPost("admissions/{id:int}/ot")]
    public Task<IActionResult> OtSave(int id, [FromBody] IpdOtSaveRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.OtBookingId, r.OtId, r.ProcedureId, r.ProcedureName, r.Laterality, r.SurgeryType,
            r.SurgeonId, r.AssistantSurgeonId, r.AnaesthetistId, r.AnaesthesiaTypeId, r.ScrubNurse, r.CirculatingNurse, r.ScheduledStart,
            r.DurationMinutes, r.PreOpDiagnosis, r.Remarks, r.IsUnplannedReturn, r.ReturnReason
        })));

    [HttpPost("ot/{bookingId:int}/cancel")]
    public Task<IActionResult> OtCancel(int bookingId, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_Cancel", new { c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.Reason })));

    [HttpPost("ot/{bookingId:int}/checklist")]
    public Task<IActionResult> OtChecklist(int bookingId, [FromBody] IpdOtChecklistRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_SaveChecklist", new { c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.Phase, r.Answers, r.Remarks })));

    [HttpPost("ot/{bookingId:int}/times")]
    public Task<IActionResult> OtTimes(int bookingId, [FromBody] IpdOtTimesRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_SaveTimes", new
        {
            c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.InOtAt, r.AnaesStartAt, r.IncisionAt, r.ClosureAt, r.AnaesEndAt, r.OutOtAt,
            r.RecoveryOutAt, r.Complete
        })));

    [HttpPost("ot/{bookingId:int}/anaesthesia")]
    public Task<IActionResult> OtAnaesthesia(int bookingId, [FromBody] IpdOtAnaesthesiaRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_SaveAnaesthesia", new
        {
            c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.AnaesthesiaTypeId, r.AsaGrade, Mallampati = (byte?)r.Mallampati, r.NpoSince,
            r.Airway, r.Comorbidities, r.PreAnaesNotes, r.Technique, r.AirwayDevice, r.Drugs, r.Monitoring, r.FluidsMl, r.BloodGivenMl, r.UrineMl,
            r.BloodLossMl, r.Complications, AldreteScore = (byte?)r.AldreteScore, r.RecoveryNotes, r.Sign
        })));

    [HttpPost("ot/{bookingId:int}/note")]
    public Task<IActionResult> OtNote(int bookingId, [FromBody] IpdOtNoteRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_SaveNote", new
        {
            c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.ProcedurePerformed, r.PostOpDiagnosis, r.Indication, r.Findings, r.ProcedureDetails,
            r.Specimens, r.SpecimenToHistopath, r.Drains, r.BloodLossMl, r.Complications, r.Closure, r.PostOpPlan, r.PatientCondition, r.Sign, r.CanSign, r.AmendReason
        })));

    [HttpPost("ot/{bookingId:int}/implants")]
    public Task<IActionResult> OtImplant(int bookingId, [FromBody] IpdOtImplantRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_AddImplant", new
        {
            c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.ItemType, r.ItemId, r.BatchId, r.StoreId, r.Qty, r.SerialNo, r.Remarks
        })));

    /// <summary>Items of the OT item type's pharmacy categories with stock in the store; then the selling stores; then whether the category exists.</summary>
    [HttpGet("ot/stock-items")]
    public Task<IActionResult> OtStockItems([FromQuery] string? itemType, [FromQuery] string? q, [FromQuery] int? storeId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOt_StockItems", new { c.CompanyId, c.BranchId, ItemType = itemType ?? "", Q = q, StoreId = storeId }, 3)));

    [HttpPost("ot-implants/{id:int}/remove")]
    public Task<IActionResult> OtImplantRemove(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_RemoveImplant", new { c.CompanyId, c.BranchId, c.UserId, ImplantId = id, r.Reason })));

    [HttpGet("ot/{bookingId:int}/charge-preview")]
    public Task<IActionResult> OtChargePreview(int bookingId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdOt_ChargePreview", new { c.CompanyId, c.BranchId, OtBookingId = bookingId })));

    [HttpPost("ot/{bookingId:int}/charges")]
    public Task<IActionResult> OtCharges(int bookingId, [FromBody] IpdOtChargesRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_PostCharges", new { c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.Lines, r.CanEditRate })));

    [HttpPost("ot/{bookingId:int}/charges/reverse")]
    public Task<IActionResult> OtChargesReverse(int bookingId, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOt_ReverseCharges", new { c.CompanyId, c.BranchId, c.UserId, OtBookingId = bookingId, r.Reason })));

    [HttpGet("ot/{bookingId:int}/print")]
    public Task<IActionResult> OtPrint(int bookingId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdOt_Print", new { c.CompanyId, c.BranchId, OtBookingId = bookingId }, 8)));

    // ── ICU ─────────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/icu")]
    public Task<IActionResult> IcuData(int id, [FromQuery] DateTime? fromAt, [FromQuery] DateTime? toAt) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdIcu_Data", new { c.CompanyId, c.BranchId, AdmissionId = id, FromAt = fromAt, ToAt = toAt }, 8)));

    [HttpPost("admissions/{id:int}/icu/observations")]
    public Task<IActionResult> IcuObservation(int id, [FromBody] IpdIcuObservationRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIcu_AddObservation", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.ObservedAt, r.Hr, r.Sbp, r.Dbp, r.Rr, r.SpO2, r.TempC, r.Cvp, r.EtCo2, r.GcsE, r.GcsV, r.GcsM,
            r.Rass, r.PainScore, r.Glucose, r.IntakeMl, r.UrineMl, r.OtherOutputMl, r.VentMode, r.FiO2, r.Peep, r.TidalVolume, r.SetRate, r.Pip, r.PressureSupport, r.Notes
        })));

    [HttpPost("icu/strike")]
    public Task<IActionResult> IcuStrike([FromBody] IpdIcuStrikeRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIcu_Strike", new { c.CompanyId, c.BranchId, c.UserId, r.Kind, r.Id, r.Reason })));

    [HttpPost("admissions/{id:int}/icu/infusions")]
    public Task<IActionResult> IcuInfusion(int id, [FromBody] IpdIcuInfusionRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIcu_Infusion", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.InfusionId, EventType = r.EventType ?? "START", r.Drug, r.Concentration, r.RateMlHr, r.Dose,
            r.Route, r.EventAt, r.Remarks
        })));

    [HttpPost("admissions/{id:int}/icu/devices")]
    public Task<IActionResult> IcuDevice(int id, [FromBody] IpdIcuDeviceRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIcu_Device", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.DeviceId, r.HeadCode, r.HeadName, r.At, r.Remarks })));

    [HttpGet("icu/board")]
    public Task<IActionResult> IcuBoard() => Run(async c => Sets(await ipd.SetsAsync("dbo.usp_Api_IpdIcu_Board", new { c.CompanyId, c.BranchId }, 3)));
}
