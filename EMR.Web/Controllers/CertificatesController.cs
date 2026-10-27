using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// OPD > Certificates (SQLScripts/2341): fitness, sick leave, fitness to resume, vaccination, disability assessment,
/// attendance and treatment certificates. Written from an OPD visit or a patient search, issued by a signing doctor of
/// the branch, verified by QR. Does not change any OPD booking, billing or consultation data.
/// </summary>
[Authorize]
public class CertificatesController(
    ICertificateService certificates,
    ICertificateNotificationService notifications,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();
    private string BaseUrl => $"{Request.Scheme}://{Request.Host}{Request.PathBase}";

    [HttpGet]
    public async Task<IActionResult> Index(string? from, string? to, string? type, string? status, string? search, int page = 1)
    {
        await certificates.EnsureMastersAsync(CompanyId);
        var f = DateTime.TryParse(from, out var fd) ? fd.Date : DateTime.Today.AddDays(-30);
        var t = DateTime.TryParse(to, out var td) ? td.Date : DateTime.Today;
        if (t < f) (f, t) = (t, f);
        var (rows, total) = await certificates.ListAsync(BranchId, f, t, type, status, search, page, 50);
        ViewBag.Types = await certificates.GetTypesAsync(CompanyId, BranchId, false);
        ViewBag.From = f; ViewBag.To = t; ViewBag.Type = type; ViewBag.Status = status; ViewBag.Search = search;
        ViewBag.Page = Math.Max(1, page); ViewBag.Total = total; ViewBag.PageSize = 50;
        return View(rows);
    }

    [HttpGet]
    public Task<IActionResult> Create(int? patientId, int? opdServiceId, string? type) => Form(null, patientId, opdServiceId, type);

    [HttpGet]
    public Task<IActionResult> Edit(int id) => Form(id, null, null, null);

    private async Task<IActionResult> Form(int? id, int? patientId, int? opdServiceId, string? type)
    {
        await certificates.EnsureMastersAsync(CompanyId);
        CertificateRecord? rec = null;
        if (id is > 0)
        {
            rec = await certificates.GetAsync(BranchId, id.Value);
            if (rec == null) return NotFound();
            if (rec.Status != "D") return RedirectToAction(nameof(Print), new { id });
            patientId = rec.PatientId; opdServiceId = rec.OPDServiceId; type = rec.TypeCode;
        }
        // from an OPD visit: its patient and doctor
        CertificateVisit? visit = null;
        if (opdServiceId is > 0)
        {
            visit = await certificates.GetVisitAsync(BranchId, opdServiceId.Value);
            if (visit == null) return NotFound("The OPD visit was not found in this branch.");
            if (patientId is not > 0) patientId = visit.PatientId;
        }
        ViewBag.Record = rec;
        ViewBag.Visit = visit;
        ViewBag.Patient = patientId is > 0 ? await certificates.GetPatientAsync(CompanyId, patientId.Value) : null;
        ViewBag.Type = type;
        ViewBag.Types = await certificates.GetTypesAsync(CompanyId, BranchId, true);
        ViewBag.Purposes = await certificates.GetPurposesAsync(CompanyId, true);
        ViewBag.Vaccines = await certificates.GetVaccinesAsync(CompanyId, true);
        ViewBag.Disabilities = await certificates.GetDisabilityTypesAsync();
        ViewBag.Doctors = await certificates.GetDoctorsAsync(CompanyId, BranchId, true);
        ViewBag.CanIssue = await permissionGuard.AllowsAsync(HttpContext, "OPD.CERTIFICATES", "ISSUE");
        return View("Form");
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatients(string term)
    {
        if (string.IsNullOrWhiteSpace(term) || term.Trim().Length < 2) return Json(Array.Empty<object>());
        var rows = await certificates.SearchPatientsAsync(CompanyId, term);
        return Json(rows.Select(p => new
        {
            p.PatientId, p.PatientCode, name = $"{p.Salutation} {p.FullName}".Trim(), p.PhoneNumber, p.Gender,
            age = p.AgeText(DateTime.Today)
        }));
    }

    /// <summary>Everything the form needs once a patient is chosen: visits, vitals / diagnosis, vaccination history.</summary>
    [HttpGet]
    public async Task<IActionResult> PatientContext(int patientId, int? opdServiceId)
    {
        var p = await certificates.GetPatientAsync(CompanyId, patientId);
        if (p == null) return Json(new { success = false, message = "Patient not found." });
        var visits = await certificates.GetVisitsAsync(CompanyId, BranchId, patientId);
        var clinical = await certificates.GetVisitClinicalAsync(CompanyId, patientId, opdServiceId);
        var vacc = await certificates.GetVaccinationsAsync(CompanyId, patientId);
        return Json(new
        {
            success = true,
            patient = new { p.PatientId, p.PatientCode, name = $"{p.Salutation} {p.FullName}".Trim(), p.Gender, age = p.AgeText(DateTime.Today),
                            p.PhoneNumber, p.Address, p.GuardianName, p.PhotoPath },
            visits = visits.Select(v => new { v.OPDServiceId, v.OPDBillNo, v.TokenNo, v.VisitDate, v.ServiceType, v.ServiceName, v.Amount, v.DoctorId, v.DoctorName }),
            clinical,
            vaccinations = vacc.Select(v => new { v.VaccinationId, v.VaccineId, v.VaccineName, v.DoseNo, v.GivenOn, v.BatchNo, v.Manufacturer, v.ExpiryDate, v.Route, v.Site, v.NextDueDate, v.CertificateId })
        });
    }

    /// <summary>Bills of the patient that charge the type's fee service and are free to link.</summary>
    [HttpGet]
    public async Task<IActionResult> FeeBills(int patientId, string type, int certificateId = 0)
    {
        var t = (await certificates.GetTypesAsync(CompanyId, BranchId, true)).FirstOrDefault(x => x.TypeCode == type);
        if (t?.FeeServiceId is not > 0) return Json(new { success = true, feeService = (object?)null, bills = Array.Empty<object>() });
        var bills = await certificates.GetFeeBillsAsync(BranchId, patientId, t.FeeServiceId.Value, certificateId);
        return Json(new
        {
            success = true,
            feeService = new { t.FeeServiceName, t.FeeAmount },
            bills = bills.Select(v => new { v.OPDServiceId, v.OPDBillNo, v.VisitDate, v.Amount, v.DoctorName })
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] CertificateSaveRequest req)
    {
        if (req == null) return Json(new { success = false, message = "Nothing to save." });
        if (req.Issue && !await permissionGuard.AllowsAsync(HttpContext, "OPD.CERTIFICATES", "ISSUE"))
            return Json(new { success = false, message = "You are not allowed to issue certificates." });
        var userId = User.GetUserId();
        var (id, error) = await certificates.SaveAsync(CompanyId, BranchId, userId, req);
        if (error != null) return Json(new { success = false, message = error });
        string? no = null;
        var notified = false;
        if (req.Issue)
        {
            (no, error) = await certificates.IssueAsync(BranchId, id, userId);
            if (error != null) return Json(new { success = false, message = error, id });
            await auditLogService.LogAsync("Certificates", "Issue", $"Certificate {no} ({req.TypeCode}) issued for patient {req.PatientId}", userId, BranchId);
            notified = await notifications.QueueOnIssueAsync(BranchId, id, userId, BaseUrl);
        }
        else
            await auditLogService.LogAsync("Certificates", "SaveDraft", $"Certificate draft {id} ({req.TypeCode}) for patient {req.PatientId}", userId, BranchId);
        return Json(new { success = true, id, certificateNo = no, notified, printUrl = Url.Action(nameof(Print), new { id }) });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Issue(int id)
    {
        var (no, error) = await certificates.IssueAsync(BranchId, id, User.GetUserId());
        if (error != null) return Json(new { success = false, message = error });
        await auditLogService.LogAsync("Certificates", "Issue", $"Certificate {no} issued", User.GetUserId(), BranchId);
        var notified = await notifications.QueueOnIssueAsync(BranchId, id, User.GetUserId(), BaseUrl);
        return Json(new { success = true, certificateNo = no, notified, printUrl = Url.Action(nameof(Print), new { id }) });
    }

    /// <summary>Sends an issued certificate to the patient again (WhatsApp + e-mail), when Hospital Settings allows it.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Notify(int id)
    {
        if (!await notifications.IsEnabledAsync(BranchId))
            return Json(new { success = false, message = "Notification Required for Issue Certificate is No in Hospital Settings > OPD Configuration." });
        var rec = await certificates.GetAsync(BranchId, id);
        if (rec?.Status != "I") return Json(new { success = false, message = "Only an issued certificate can be sent." });
        var outcomes = await notifications.SendAsync(BranchId, id, User.GetUserId(), BaseUrl);
        await auditLogService.LogAsync("Certificates", "Notify", $"Certificate {rec.CertificateNo} sent to patient: " +
            string.Join(", ", outcomes.Select(o => $"{o.Channel} {o.Status}")), User.GetUserId(), BranchId);
        return Json(new { success = true, outcomes = outcomes.Select(o => new { o.Channel, o.Status, o.Message }) });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string reason)
    {
        var rec = await certificates.GetAsync(BranchId, id);
        var error = await certificates.CancelAsync(BranchId, id, User.GetUserId(), reason);
        if (error != null) return Json(new { success = false, message = error });
        await auditLogService.LogAsync("Certificates", "Cancel", $"Certificate {rec?.CertificateNo ?? "draft " + id} cancelled: {reason}", User.GetUserId(), BranchId);
        return Json(new { success = true });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reissue(int id)
    {
        var (newId, error) = await certificates.ReissueAsync(BranchId, id, User.GetUserId());
        if (error != null) return Json(new { success = false, message = error });
        await auditLogService.LogAsync("Certificates", "Reissue", $"Certificate {id} reissued as draft {newId}", User.GetUserId(), BranchId);
        return Json(new { success = true, editUrl = Url.Action(nameof(Edit), new { id = newId }) });
    }

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var m = await certificates.GetPrintModelAsync(BranchId, id);
        if (m == null) return NotFound();
        if (m.Certificate.VerifyToken is { Length: > 0 } token)
            m.VerifyUrl = $"{BaseUrl}/verify/certificate/{token}";
        if (m.Certificate.Status == "I") await certificates.MarkPrintedAsync(id);
        ViewBag.CanCancel = await permissionGuard.AllowsAsync(HttpContext, "OPD.CERTIFICATES", "CANCEL");
        ViewBag.CanReissue = await permissionGuard.AllowsAsync(HttpContext, "OPD.CERTIFICATES", "REISSUE");
        ViewBag.NotifyEnabled = await notifications.IsEnabledAsync(BranchId);
        ViewBag.CanNotify = await permissionGuard.AllowsAsync(HttpContext, "OPD.CERTIFICATES", "ISSUE");
        ViewBag.NotifyLog = m.Certificate.Status == "I" ? await notifications.GetLogAsync(id) : new List<CertificateNotificationRow>();
        return View(m);
    }

    /// <summary>Public check of a certificate's QR code: number, type, status, date and doctor only.</summary>
    [HttpGet, AllowAnonymous, Route("verify/certificate/{token}")]
    public async Task<IActionResult> Verify(string token)
    {
        var m = await certificates.VerifyAsync(token);
        return View(m);
    }
}
