using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

// ── request bodies (JSON arrays / objects are passed through to the procedures as text) ───────────────────────
public record IpdAdmitRequest(Guid? RequestKey, int PatientId, DateTime? AdmissionAt, string AdmissionType, string AdmissionSource, int? OpdServiceId,
    int? ReferralDoctorId, int AdmittingDoctorId, int ConsultantDoctorId, int? DepartmentId, string? ProvisionalDiagnosis, string? DiagnosisCode,
    string? ReasonForAdmission, DateTime? ExpectedDischargeAt, int BedId, int TariffCategoryId, string PayerType, int? PackageId, int? EstimateId,
    string? Remarks, string? Payers, string? Attendants, bool IsMlc, string? Mlc, string? Consent, string? Payments,
    bool CanWaiveAdvance, string? AdvanceWaiveReason, bool CanBackdate);
public record IpdUpdateRequest(string AdmissionType, string AdmissionSource, int? ReferralDoctorId, int AdmittingDoctorId, int ConsultantDoctorId,
    int? DepartmentId, string? ProvisionalDiagnosis, string? DiagnosisCode, string? ReasonForAdmission, DateTime? ExpectedDischargeAt,
    int TariffCategoryId, string PayerType, int? PackageId, string? Remarks, string? Payers, string? Attendants, bool IsMlc, string? Mlc, bool CanChangeTariff);
public record IpdReasonRequest(string? Reason);
public record IpdChargeAddRequest(string Lines, bool CanEditRate, bool CanDiscount);
public record IpdDoctorFeeRequest(int? FeeId, int DoctorId, string? VisitType, int? TariffCategoryId, decimal Rate, DateTime EffectiveFrom, DateTime? EffectiveTo, string? Remarks);
public record IpdLabOrderRequest(string Items, int? DoctorId, string? Remarks);
public record IpdPhIssueRequest(string Lines, string? Head, int? StoreId, int? DoctorId, string? Remarks);
public record IpdPhReturnRequest(string Lines, string? Reason);
public record IpdAdviceRequest(int OpdServiceId, string? Reason, string? Diagnosis, string? DiagnosisCode, string? Urgency, DateTime? ExpectedAt, int? DepartmentId, string? Remarks);
public record IpdPackageRequest(int? PackageId, string? Reason);
public record IpdFinaliseRequest(DateTime? UpTo, string? DiscountType, decimal DiscountValue, string? DiscountReason, string? Remarks, bool CanDiscount, bool CanBackdate);
public record IpdCancelRequest(string? Reason, string? RefundMethod, string? RefundRefNo);
public record IpdAdvanceRequest(string Payments, string? Remarks);
public record IpdRefundRequest(decimal Amount, string Method, string? RefNo, string? Reason);
public record IpdConsentRequest(int ConsentId, string? SignedByName, string? SignedByRelation, string? WitnessName, string? SignaturePath, string? WitnessSignaturePath);
public record IpdDocumentRequest(string? DocType, string? Title, string FilePath, string? Remarks);
public record IpdPreEstimateRequest(int? EstimateId, int? PatientId, string? PatientName, string? Phone, string? AgeText, string? Gender, string PayerType,
    int TariffCategoryId, int? BedCategoryId, int WardDays, int? IcuBedCategoryId, int IcuDays, int? PackageId, int? DoctorId, string? ProcedureNote,
    string? Remarks, string Lines);

public record IpdTransferRequest(int ToBedId, DateTime? TransferAt, string? Reason, bool UpdateDepartment, bool CanBackdate);
public record IpdSwapRequest(int OtherAdmissionId, string? Reason);
public record IpdBedStatusRequest(string Status, string? Reason);
public record IpdReserveRequest(int? PatientId, string? PatientName, string? Phone, DateTime ExpectedAdmitAt, int? HoldHours, int? DoctorId, int? EstimateId, string? Remarks);
public record IpdCleaningRequest(string Action, int? StaffUserId, string? Remarks);

/// <summary>
/// IPD transactions (SQLScripts/2422-2424): admission, beds, advances, consents, documents, dashboard and the
/// real-time billing estimate. The company, branch and user always come from the caller's token, never the request.
/// </summary>
[ApiController]
[Route("api/ipd")]
[Produces("application/json")]
public class IpdController(IIpdProcService ipd) : ControllerBase
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

    private IActionResult NoCaller() =>
        BadRequest(ApiResponse.Fail("IPD needs a signed-in user with a selected branch."));

    private async Task<IActionResult> Run(Func<(int CompanyId, int BranchId, int UserId), Task<IActionResult>> work) =>
        Caller() is { } c ? await work(c) : NoCaller();

    // ── lookups, beds, dashboard ──────────────────────────────────────────────────────────────────────────────
    [HttpGet("lookups")]
    public Task<IActionResult> Lookups() => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_Ipd_Lookups", new { c.CompanyId, c.BranchId }, 19)));

    [HttpGet("beds")]
    public Task<IActionResult> Beds([FromQuery] int? tariffCategoryId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_Ipd_Beds", new { c.CompanyId, c.BranchId, TariffCategoryId = tariffCategoryId })));

    [HttpGet("dashboard")]
    public Task<IActionResult> Dashboard() => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_Ipd_Dashboard", new { c.CompanyId, c.BranchId }, 3)));

    [HttpGet("patients/{patientId:int}/status")]
    public Task<IActionResult> PatientStatus(int patientId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_Ipd_PatientStatus", new { c.CompanyId, c.BranchId, PatientId = patientId }, 3)));

    [HttpGet("consent-templates/{consentId:int}")]
    public Task<IActionResult> ConsentTemplate(int consentId) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_Ipd_ConsentTemplate", new { c.BranchId, ConsentId = consentId })));

    // ── admissions ────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions")]
    public Task<IActionResult> List([FromQuery] string? status, [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] string? search,
        [FromQuery] int? wardId, [FromQuery] string? payerType, [FromQuery] int page = 1, [FromQuery] int pageSize = 25) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdAdmission_List", new
        {
            c.CompanyId, c.BranchId, Status = status, FromDate = fromDate?.Date, ToDate = toDate?.Date, Search = search, WardId = wardId,
            PayerType = payerType, Page = page, PageSize = pageSize
        }, 2)));

    [HttpGet("admissions/{id:int}")]
    public Task<IActionResult> Get(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdAdmission_Get", new { c.CompanyId, AdmissionId = id }, 9)));

    [HttpPost("admissions")]
    public Task<IActionResult> Admit([FromBody] IpdAdmitRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdmission_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, r.RequestKey, r.PatientId, r.AdmissionAt, r.AdmissionType, r.AdmissionSource, r.OpdServiceId,
            r.ReferralDoctorId, r.AdmittingDoctorId, r.ConsultantDoctorId, r.DepartmentId, r.ProvisionalDiagnosis, r.DiagnosisCode, r.ReasonForAdmission,
            r.ExpectedDischargeAt, r.BedId, r.TariffCategoryId, r.PayerType, r.PackageId, r.EstimateId, r.Remarks, r.Payers, r.Attendants, r.IsMlc,
            r.Mlc, r.Consent, r.Payments, r.CanWaiveAdvance, r.AdvanceWaiveReason, r.CanBackdate
        })));

    [HttpPost("admissions/{id:int}/update")]
    public Task<IActionResult> Update(int id, [FromBody] IpdUpdateRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdmission_Update", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.AdmissionType, r.AdmissionSource, r.ReferralDoctorId, r.AdmittingDoctorId,
            r.ConsultantDoctorId, r.DepartmentId, r.ProvisionalDiagnosis, r.DiagnosisCode, r.ReasonForAdmission, r.ExpectedDischargeAt,
            r.TariffCategoryId, r.PayerType, r.PackageId, r.Remarks, r.Payers, r.Attendants, r.IsMlc, r.Mlc, r.CanChangeTariff
        })));

    [HttpPost("admissions/{id:int}/cancel")]
    public Task<IActionResult> Cancel(int id, [FromBody] IpdCancelRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdmission_Cancel", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Reason, r.RefundMethod, r.RefundRefNo })));

    // ── advances ──────────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("admissions/{id:int}/advance")]
    public Task<IActionResult> Advance(int id, [FromBody] IpdAdvanceRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdvance_Add", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Payments, r.Remarks })));

    [HttpPost("admissions/{id:int}/refund")]
    public Task<IActionResult> Refund(int id, [FromBody] IpdRefundRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdvance_Refund", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Amount, r.Method, r.RefNo, r.Reason })));

    [HttpGet("advances/{id:int}")]
    public Task<IActionResult> AdvanceGet(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdAdvance_Get", new { c.CompanyId, AdvanceId = id }, 3)));

    // ── consents, documents ───────────────────────────────────────────────────────────────────────────────────
    [HttpPost("admissions/{id:int}/consents")]
    public Task<IActionResult> Consent(int id, [FromBody] IpdConsentRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdConsent_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.ConsentId, r.SignedByName, r.SignedByRelation, r.WitnessName, r.SignaturePath, r.WitnessSignaturePath
        })));

    [HttpGet("consents/{id:int}")]
    public Task<IActionResult> ConsentGet(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdConsent_Get", new { c.CompanyId, AdmissionConsentId = id }, 2)));

    [HttpPost("admissions/{id:int}/documents")]
    public Task<IActionResult> Document(int id, [FromBody] IpdDocumentRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDocument_Save", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.DocType, r.Title, r.FilePath, r.Remarks })));

    [HttpPost("documents/{id:int}/remove")]
    public Task<IActionResult> DocumentRemove(int id) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDocument_Remove", new { c.CompanyId, c.BranchId, c.UserId, DocumentId = id })));

    // ── current billing estimation (real time) ────────────────────────────────────────────────────────────────
    [HttpGet("estimate/{id:int}")]
    public Task<IActionResult> Estimate(int id, [FromQuery] DateTime? asOf, [FromQuery] DateTime? projectTo) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdEstimate_Live", new { c.CompanyId, AdmissionId = id, AsOf = asOf, ProjectTo = projectTo }, 4)));

    [HttpGet("estimate/{id:int}/lines")]
    public Task<IActionResult> EstimateLines(int id, [FromQuery] DateTime? asOf, [FromQuery] string? head, [FromQuery] string? status,
        [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] string? search) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdEstimate_Lines", new
        {
            c.CompanyId, AdmissionId = id, AsOf = asOf, Head = head, Status = status, FromDate = fromDate?.Date, ToDate = toDate?.Date, Search = search
        })));

    [HttpGet("estimate/due-list")]
    public Task<IActionResult> DueList([FromQuery] int? wardId, [FromQuery] string? payerType, [FromQuery] string? search, [FromQuery] bool onlyAlerts = false) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdEstimate_DueList", new { c.CompanyId, c.BranchId, WardId = wardId, PayerType = payerType, Search = search, OnlyAlerts = onlyAlerts })));

    // ── pre-admission estimate ────────────────────────────────────────────────────────────────────────────────
    [HttpGet("pre-estimates")]
    public Task<IActionResult> PreEstimates([FromQuery] string? status, [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] string? search,
        [FromQuery] int? patientId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdPreEstimate_List", new
        {
            c.CompanyId, c.BranchId, Status = status, FromDate = fromDate?.Date, ToDate = toDate?.Date, Search = search, PatientId = patientId
        })));

    [HttpGet("pre-estimates/{id:int}")]
    public Task<IActionResult> PreEstimate(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdPreEstimate_Get", new { c.CompanyId, EstimateId = id }, 2)));

    [HttpGet("pre-estimates/calc")]
    public Task<IActionResult> PreEstimateCalc([FromQuery] int tariffCategoryId, [FromQuery] int? bedCategoryId, [FromQuery] int wardDays,
        [FromQuery] int? icuBedCategoryId, [FromQuery] int icuDays, [FromQuery] int? packageId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdPreEstimate_Calc", new
        {
            c.CompanyId, c.BranchId, TariffCategoryId = tariffCategoryId, BedCategoryId = bedCategoryId, WardDays = wardDays,
            IcuBedCategoryId = icuBedCategoryId, IcuDays = icuDays, PackageId = packageId
        }, 2)));

    [HttpPost("pre-estimates")]
    public Task<IActionResult> PreEstimateSave([FromBody] IpdPreEstimateRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPreEstimate_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, r.EstimateId, r.PatientId, r.PatientName, r.Phone, r.AgeText, r.Gender, r.PayerType, r.TariffCategoryId,
            r.BedCategoryId, r.WardDays, r.IcuBedCategoryId, r.IcuDays, r.PackageId, r.DoctorId, r.ProcedureNote, r.Remarks, r.Lines
        })));

    [HttpPost("pre-estimates/{id:int}/cancel")]
    public Task<IActionResult> PreEstimateCancel(int id) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPreEstimate_Cancel", new { c.CompanyId, c.BranchId, c.UserId, EstimateId = id })));
    // ── Phase 2: bed management (SQLScripts/2431) ───────────────────────────────────────────────────────────────
    [HttpGet("beds/board")]
    public Task<IActionResult> BedBoard() => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBed_Board", new { c.CompanyId, c.BranchId }, 4)));

    [HttpGet("beds/{bedId:int}/history")]
    public Task<IActionResult> BedHistory(int bedId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBed_History", new { c.CompanyId, c.BranchId, BedId = bedId }, 2)));

    [HttpGet("beds/for-transfer/{admissionId:int}")]
    public Task<IActionResult> BedsForTransfer(int admissionId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdBed_ForTransfer", new { c.CompanyId, c.BranchId, AdmissionId = admissionId })));

    [HttpGet("census")]
    public Task<IActionResult> Census([FromQuery] DateTime fromDate, [FromQuery] DateTime toDate) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_Ipd_Census", new { c.CompanyId, c.BranchId, FromDate = fromDate.Date, ToDate = toDate.Date })));

    [HttpPost("admissions/{id:int}/transfer")]
    public Task<IActionResult> Transfer(int id, [FromBody] IpdTransferRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_Transfer", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.ToBedId, r.TransferAt, r.Reason, r.UpdateDepartment, r.CanBackdate
        })));

    [HttpPost("admissions/{id:int}/swap")]
    public Task<IActionResult> Swap(int id, [FromBody] IpdSwapRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_Swap", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.OtherAdmissionId, r.Reason })));

    [HttpPost("beds/{bedId:int}/status")]
    public Task<IActionResult> BedStatus(int bedId, [FromBody] IpdBedStatusRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_SetStatus", new { c.CompanyId, c.BranchId, c.UserId, BedId = bedId, r.Status, r.Reason })));

    [HttpPost("beds/{bedId:int}/reserve")]
    public Task<IActionResult> Reserve(int bedId, [FromBody] IpdReserveRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_Reserve", new
        {
            c.CompanyId, c.BranchId, c.UserId, BedId = bedId, r.PatientId, r.PatientName, r.Phone, r.ExpectedAdmitAt, r.HoldHours, r.DoctorId, r.EstimateId, r.Remarks
        })));

    [HttpPost("reservations/{id:int}/release")]
    public Task<IActionResult> ReleaseReservation(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_ReleaseReservation", new { c.CompanyId, c.BranchId, c.UserId, ReservationId = id, r.Reason })));

    [HttpPost("cleaning/{id:int}")]
    public Task<IActionResult> Cleaning(int id, [FromBody] IpdCleaningRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBed_Cleaning", new { c.CompanyId, c.BranchId, c.UserId, CleaningTaskId = id, r.Action, r.StaffUserId, r.Remarks })));
    // ── ICD-10 search (SQLScripts/2433) ────────────────────────────────────────────────────────────────────────
    [HttpGet("icd")]
    public Task<IActionResult> Icd([FromQuery] string? q) => Run(async c => Rows(await ipd.RowsAsync("dbo.usp_Api_Icd_Search", new { Q = q ?? "", Top = 20 })));

    // ── billing (SQLScripts/2434) ───────────────────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/charge-lookups")]
    public Task<IActionResult> ChargeLookups(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_Ipd_ChargeLookups", new { c.CompanyId, c.BranchId, AdmissionId = id }, 5)));

    [HttpGet("admissions/{id:int}/charges")]
    public Task<IActionResult> Charges(int id, [FromQuery] string? head, [FromQuery] bool includeCancelled = false) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdCharge_List", new { c.CompanyId, AdmissionId = id, Head = head, IncludeCancelled = includeCancelled })));

    [HttpPost("admissions/{id:int}/charges")]
    public Task<IActionResult> ChargeAdd(int id, [FromBody] IpdChargeAddRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdCharge_Add", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Lines, r.CanEditRate, r.CanDiscount })));

    [HttpPost("charges/{id:long}/cancel")]
    public Task<IActionResult> ChargeCancel(long id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdCharge_Cancel", new { c.CompanyId, c.BranchId, c.UserId, ChargeId = id, r.Reason })));

    [HttpPost("admissions/{id:int}/package")]
    public Task<IActionResult> SetPackage(int id, [FromBody] IpdPackageRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBill_SetPackage", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.PackageId, r.Reason })));

    [HttpGet("admissions/{id:int}/bill-preview")]
    public Task<IActionResult> BillPreview(int id, [FromQuery] DateTime? upTo, [FromQuery] string? discountType, [FromQuery] decimal discountValue = 0) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBill_Preview", new { c.CompanyId, AdmissionId = id, UpTo = upTo, DiscountType = discountType, DiscountValue = discountValue }, 2)));

    [HttpPost("admissions/{id:int}/final-bill")]
    public Task<IActionResult> Finalise(int id, [FromBody] IpdFinaliseRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBill_Finalise", new
        {
            c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.UpTo, r.DiscountType, r.DiscountValue, r.DiscountReason, r.Remarks, r.CanDiscount, r.CanBackdate
        })));

    [HttpPost("bills/{id:int}/cancel")]
    public Task<IActionResult> BillCancel(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdBill_Cancel", new { c.CompanyId, c.BranchId, c.UserId, BillId = id, r.Reason })));

    [HttpGet("bills/{id:int}")]
    public Task<IActionResult> BillGet(int id) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdBill_Get", new { c.CompanyId, BillId = id }, 5)));

    [HttpGet("bills")]
    public Task<IActionResult> Bills([FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, [FromQuery] string? status, [FromQuery] string? search) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdBill_List", new { c.CompanyId, c.BranchId, FromDate = fromDate, ToDate = toDate, Status = status, Search = search })));

    // ── IPD > Doctor Visit Charges (SQLScripts/2434) ────────────────────────────────────────────────────────────
    [HttpGet("doctor-fees/lookups")]
    public Task<IActionResult> DoctorFeeLookups() => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdDoctorFee_Lookups", new { c.CompanyId, c.BranchId }, 2)));

    [HttpGet("doctor-fees")]
    public Task<IActionResult> DoctorFees([FromQuery] int? doctorId, [FromQuery] string? search, [FromQuery] bool includeInactive = false) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdDoctorFee_List", new { c.CompanyId, c.BranchId, DoctorId = doctorId, Search = search, IncludeInactive = includeInactive })));

    [HttpPost("doctor-fees")]
    public Task<IActionResult> DoctorFeeSave([FromBody] IpdDoctorFeeRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDoctorFee_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, r.FeeId, r.DoctorId, r.VisitType, r.TariffCategoryId, r.Rate,
            EffectiveFrom = r.EffectiveFrom.Date, EffectiveTo = r.EffectiveTo?.Date, r.Remarks
        })));

    [HttpPost("doctor-fees/{id:int}/remove")]
    public Task<IActionResult> DoctorFeeRemove(int id) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdDoctorFee_Remove", new { c.CompanyId, c.BranchId, c.UserId, FeeId = id })));

    // ── LAB / radiology orders (SQLScripts/2436) ─────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/lab-items")]
    public Task<IActionResult> LabItems(int id, [FromQuery] string? kind) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdLab_Items", new { c.CompanyId, c.BranchId, AdmissionId = id, Kind = kind }, 2)));

    [HttpGet("admissions/{id:int}/lab-orders")]
    public Task<IActionResult> LabOrders(int id, [FromQuery] string? kind, [FromQuery] bool includeCancelled = false) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdLab_List", new { c.CompanyId, AdmissionId = id, Kind = kind, IncludeCancelled = includeCancelled })));

    /// <summary>The order, then (as the LAB booking screen does after a paid bill) its sample rows, token and auto-collection.</summary>
    [HttpPost("admissions/{id:int}/lab-orders")]
    public Task<IActionResult> LabOrder(int id, [FromBody] IpdLabOrderRequest r) => Run(async c =>
    {
        var row = await ipd.RowAsync("dbo.usp_Api_IpdLab_Order", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Items, r.DoctorId, r.Remarks });
        if (row is not null && row.TryGetValue("Success", out var ok) && ok is true && row.TryGetValue("LabOrderId", out var o) && o is int labOrderId)
        {
            await ipd.ExecAsync("dbo.usp_CreateSampleCollectionFromLabOrder", new { LabOrderId = labOrderId, c.BranchId, c.CompanyId, CreatedBy = c.UserId });
            var p = new Dapper.DynamicParameters();
            p.Add("@LabOrderId", labOrderId);
            p.Add("@TokenNo", dbType: System.Data.DbType.String, size: 50, direction: System.Data.ParameterDirection.Output);
            await ipd.ExecAsync("dbo.usp_LAB_AssignTokenOnPayment", p);
            row["TokenNo"] = p.Get<string?>("@TokenNo");
            try { await ipd.ExecAsync("dbo.usp_SampleCollection_AutoCollectIfNoMandatory", new { LabOrderId = labOrderId, UserId = c.UserId }); }
            catch { /* as on the LAB booking screen: never fails the order */ }
        }
        return Row(row);
    });

    [HttpPost("lab-items/{id:int}/cancel")]
    public Task<IActionResult> LabCancel(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdLab_CancelItem", new { c.CompanyId, c.BranchId, c.UserId, LabOrderItemId = id, r.Reason })));

    // ── pharmacy issue / return (SQLScripts/2437) ────────────────────────────────────────────────────────────────
    [HttpGet("admissions/{id:int}/ph-items")]
    public Task<IActionResult> PhItems(int id, [FromQuery] string? q, [FromQuery] int? storeId) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdPh_Items", new { c.CompanyId, c.BranchId, Q = q, StoreId = storeId }, 2)));

    [HttpGet("ph-batches/{itemId:int}")]
    public Task<IActionResult> PhBatches(int itemId, [FromQuery] int? storeId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_PhSale_Batches", new { c.CompanyId, c.BranchId, ItemId = itemId, StoreId = storeId })));

    [HttpGet("admissions/{id:int}/ph-issues")]
    public Task<IActionResult> PhIssues(int id, [FromQuery] string? head) => Run(async c =>
        Sets(await ipd.SetsAsync("dbo.usp_Api_IpdPh_List", new { c.CompanyId, AdmissionId = id, Head = head }, 2)));

    [HttpPost("admissions/{id:int}/ph-issues")]
    public Task<IActionResult> PhIssue(int id, [FromBody] IpdPhIssueRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPh_Issue", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Lines, r.Head, r.StoreId, r.DoctorId, r.Remarks })));

    [HttpPost("admissions/{id:int}/ph-returns")]
    public Task<IActionResult> PhReturn(int id, [FromBody] IpdPhReturnRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdPh_Return", new { c.CompanyId, c.BranchId, c.UserId, AdmissionId = id, r.Lines, r.Reason })));

    // ── OPD admission advice (SQLScripts/2438) ────────────────────────────────────────────────────────────────────
    [HttpGet("advice")]
    public Task<IActionResult> Advice([FromQuery] string? status, [FromQuery] int? opdServiceId) => Run(async c =>
        Rows(await ipd.RowsAsync("dbo.usp_Api_IpdAdvice_List", new { c.CompanyId, c.BranchId, Status = status ?? "PENDING", OpdServiceId = opdServiceId })));

    [HttpGet("advice/departments")]
    public Task<IActionResult> AdviceDepartments() => Run(async c => Rows(await ipd.RowsAsync("dbo.usp_Api_IpdAdvice_Departments", new { c.CompanyId })));

    [HttpPost("advice")]
    public Task<IActionResult> AdviceSave([FromBody] IpdAdviceRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdvice_Save", new
        {
            c.CompanyId, c.BranchId, c.UserId, r.OpdServiceId, r.Reason, r.Diagnosis, r.DiagnosisCode, r.Urgency, r.ExpectedAt, r.DepartmentId, r.Remarks
        })));

    [HttpPost("advice/{id:int}/cancel")]
    public Task<IActionResult> AdviceCancel(int id, [FromBody] IpdReasonRequest r) => Run(async c =>
        Row(await ipd.RowAsync("dbo.usp_Api_IpdAdvice_Cancel", new { c.CompanyId, c.BranchId, c.UserId, AdviceId = id, r.Reason })));
}
