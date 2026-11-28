using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record IpdAssessmentRequest(string Kind, string Data, bool Sign, string? AmendReason);
public record IpdNoteRequest(int? NoteId, string NoteType, int? DoctorId, DateTime? NoteAt, string? Subjective, string? Objective, string? Assessment,
    string? PlanText, bool Sign, int? CrossConsultId);
public record IpdOrderRequest(string OrderType, string? Priority, int? DoctorId, string? Source, bool ReadBack, int? ItemId, string? DrugName, string? Dose,
    string? Route, string? FrequencyCode, DateTime? StartAt, int? DurationDays, string? ServiceKind, int? RefId, decimal? Qty, string? DietType, string? Details,
    string? AllergyOverride = null, string? InteractionOverride = null);
public record IpdOrderActionRequest(string Action, string? Reason, DateTime? At, int? IndentId);
public record IpdCrossConsultRequest(int? ConsultId, int? ToDoctorId, string? Urgency, string? Reason, bool Cancel, string? CancelReason);
public record IpdMarRequest(DateTime? DueAt, string Outcome, DateTime? GivenAt, string? DoseGiven, string? Site, string? Reason, string? WitnessName, string? ScanValue = null);
public record IpdVitalRequest(DateTime? ObservedAt, short? Rr, decimal? SpO2, bool? OnOxygen, string? O2Device, decimal? O2FlowLpm, short? Sbp, short? Dbp,
    short? Pulse, string? Consciousness, decimal? TempC, byte? PainScore, decimal? Glucose, decimal? WeightKg, string? Notes);
public record IpdIoRequest(DateTime? At, string Direction, string Category, int VolumeMl, string? Notes);
public record IpdNursingNoteRequest(DateTime? NoteAt, string? Shift, string? Note);
public record IpdRiskRequest(string Kind, string Answers, DateTime? AssessedAt, string? Interventions);
public record IpdCarePlanRequest(int? PlanId, string? Problem, string? Goal, string? Interventions, bool Resolve, string? Evaluation);
public record IpdHandoverRequest(int? HandoverId, string? Shift, string? Situation, string? Background, string? AssessmentText, string? Recommendation, bool Receive);
public record IpdIncidentRequest(int? IncidentId, string? IncidentType, string? Severity, DateTime? OccurredAt, string? Location, string? Description,
    string? ImmediateAction, bool DoctorInformed, bool Close, string? Closure);
public record IpdClinicalStrikeRequest(string Kind, long Id, string? Reason);

/// <summary>
/// IPD Phase 3 (SQLScripts/2562-2565): doctor and nursing clinical documentation - initial assessments, rounds / progress notes,
/// CPOE orders with verbal-order countersign, cross-consultation, eMAR, vitals with NEWS2, intake / output, nursing notes,
/// Morse / Braden risk, care plan, SBAR handover, incidents and the Nursing Station worklist. Company, branch and user come from the token.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdClinicalController(IIpdProcService ipd) : ControllerBase
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

    // ── reads ──────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/clinical")]
    public Task<IActionResult> Clinical(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdClinical_Data", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id }, 7)));

    [HttpGet("admissions/{id:int}/nursing")]
    public Task<IActionResult> Nursing(int id, [FromQuery] DateTime? fromAt, [FromQuery] DateTime? toAt) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdNursing_Data", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, FromAt = fromAt, ToAt = toAt }, 11)));

    [HttpGet("clinical/services")]
    public Task<IActionResult> Services([FromQuery] string? q) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdOrder_Services", new { c.CompanyId, c.BranchId, Q = q })));

    [HttpGet("nursing-station")]
    public Task<IActionResult> Station([FromQuery] int? stationId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdNursingStation_Board", new { c.CompanyId, c.BranchId, c.UserId, StationId = stationId }, 2)));

    // ── doctor ─────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("admissions/{id:int}/assessment")]
    public Task<IActionResult> Assessment(int id, [FromBody] IpdAssessmentRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAssessment_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Kind, r.Data, r.Sign, r.AmendReason })));

    [HttpPost("admissions/{id:int}/notes")]
    public Task<IActionResult> Note(int id, [FromBody] IpdNoteRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdNote_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.NoteId, r.NoteType, r.DoctorId, r.NoteAt, r.Subjective, r.Objective, r.Assessment, r.PlanText,
            r.Sign, r.CrossConsultId
        })));

    [HttpPost("admissions/{id:int}/orders")]
    public Task<IActionResult> Order(int id, [FromBody] IpdOrderRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOrder_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.OrderType, r.Priority, r.DoctorId, r.Source, r.ReadBack, r.ItemId, r.DrugName, r.Dose,
            r.Route, r.FrequencyCode, r.StartAt, r.DurationDays, r.ServiceKind, r.RefId, r.Qty, r.DietType, r.Details, r.AllergyOverride, r.InteractionOverride
        })));

    [HttpPost("orders/{orderId:int}/action")]
    public Task<IActionResult> OrderAction(int orderId, [FromBody] IpdOrderActionRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdOrder_Action", new { c.CompanyId, c.BranchId, c.UserId, OrderId = orderId, r.Action, r.Reason, r.At, r.IndentId })));

    [HttpPost("admissions/{id:int}/cross-consults")]
    public Task<IActionResult> CrossConsult(int id, [FromBody] IpdCrossConsultRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdCrossConsult_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.ConsultId, r.ToDoctorId, r.Urgency, r.Reason, r.Cancel, r.CancelReason
        })));

    // ── nursing ────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("orders/{orderId:int}/mar")]
    public Task<IActionResult> Mar(int orderId, [FromBody] IpdMarRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdMar_Record", new
        {
            c.CompanyId, c.BranchId, c.UserId, OrderId = orderId, r.DueAt, r.Outcome, r.GivenAt, r.DoseGiven, r.Site, r.Reason, r.WitnessName, r.ScanValue
        })));

    [HttpPost("admissions/{id:int}/vitals")]
    public Task<IActionResult> Vital(int id, [FromBody] IpdVitalRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdVital_Add", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.ObservedAt, r.Rr, r.SpO2, r.OnOxygen, r.O2Device, r.O2FlowLpm, r.Sbp, r.Dbp, r.Pulse,
            r.Consciousness, r.TempC, r.PainScore, r.Glucose, r.WeightKg, r.Notes
        })));

    [HttpPost("admissions/{id:int}/intake-output")]
    public Task<IActionResult> IntakeOutput(int id, [FromBody] IpdIoRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIo_Add", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.At, r.Direction, r.Category, r.VolumeMl, r.Notes })));

    [HttpPost("admissions/{id:int}/nursing-notes")]
    public Task<IActionResult> NursingNote(int id, [FromBody] IpdNursingNoteRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdNursingNote_Add", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.NoteAt, r.Shift, r.Note })));

    [HttpPost("admissions/{id:int}/risk")]
    public Task<IActionResult> Risk(int id, [FromBody] IpdRiskRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdRisk_Add", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Kind, r.Answers, r.AssessedAt, r.Interventions })));

    [HttpPost("admissions/{id:int}/care-plan")]
    public Task<IActionResult> CarePlan(int id, [FromBody] IpdCarePlanRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdCarePlan_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.PlanId, r.Problem, r.Goal, r.Interventions, r.Resolve, r.Evaluation
        })));

    [HttpPost("admissions/{id:int}/handover")]
    public Task<IActionResult> Handover(int id, [FromBody] IpdHandoverRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdHandover_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.HandoverId, r.Shift, r.Situation, r.Background, r.AssessmentText, r.Recommendation, r.Receive
        })));

    [HttpPost("admissions/{id:int}/incidents")]
    public Task<IActionResult> Incident(int id, [FromBody] IpdIncidentRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdIncident_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.IncidentId, r.IncidentType, r.Severity, r.OccurredAt, r.Location, r.Description,
            r.ImmediateAction, r.DoctorInformed, r.Close, r.Closure
        })));

    [HttpPost("clinical/strike")]
    public Task<IActionResult> Strike([FromBody] IpdClinicalStrikeRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdClinical_Strike", new { c.CompanyId, c.BranchId, c.UserId, r.Kind, r.Id, r.Reason })));
}
