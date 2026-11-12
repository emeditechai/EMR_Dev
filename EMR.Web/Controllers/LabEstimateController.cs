using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// LAB > B2C Bill Estimate (SQLScripts/2451): a billing simulator on one page - the B2C booking's tests / profiles /
/// packages (the branch's B2C rate list), misc charges and discounts (overall % / ₹, or department-wise), worked out by
/// the server (usp_LabEstimate_Compute). Generate saves an estimate (no bill, payment or sample); it can be printed,
/// downloaded as PDF and sent to the patient's WhatsApp with a link that opens without sign-in.
/// Page LAB.LABESTIMATE: VIEW, ADD, DISCOUNT, SEND, CANCEL. Web -> EMR.Api api/lab-estimates -> procedures.
/// </summary>
[Authorize]
public class LabEstimateController(LabEstimateApiClient api, ILabOrderApiClient labOrders, IActionPermissionGuard permissionGuard,
    IAuditLogService auditLogService, IWhatsAppService whatsApp, IPatientService patientService, EMR.Web.Data.ApplicationDbContext dbContext,
    ILogger<LabEstimateController> logger) : Controller
{
    public const string Page = "LAB.LABESTIMATE";
    private int Branch => HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 0;
    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string control) => permissionGuard.AllowsAsync(HttpContext, Page, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        if (Branch <= 0) return Fail("Your branch could not be found - sign in again.");
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Estimate API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        foreach (var c in new[] { "ADD", "DISCOUNT", "SEND", "CANCEL" }) ViewData["Can" + c] = await Can(c);
        return View();
    }

    // ── form data ───────────────────────────────────────────────────────────────────────────────────────────
    /// <summary>Bookable B2C tests / profiles / packages of the branch (same list as LAB > B2C Booking).</summary>
    [HttpGet]
    public Task<IActionResult> Tests(string? gender, int? ageInYears) => Read(async () =>
        (await labOrders.GetAvailableInvestigationsAsync(Branch, null, null, null, string.IsNullOrWhiteSpace(gender) ? null : gender, ageInYears, "B2C", null))
            .Select(t => new { t.InvestigationId, t.TestCode, t.TestName, t.MRP, t.IsProfileTest, t.IsPackage, t.IsDiscountAllowed, t.SampleType, t.TATHours, t.IsOutsourced }));

    /// <summary>Tests inside a profile / package (for the add-test checks of B2C Booking).</summary>
    [HttpGet] public Task<IActionResult> Includes(string kind, int id) => Read(async () => await api.GetAsync("/includes" + IpdApiClient.Q(("kind", kind), ("id", id.ToString()))));
    [HttpGet] public Task<IActionResult> MiscCharges() => Read(async () => await api.GetAsync("/misc-charges"));
    [HttpGet] public Task<IActionResult> Doctors() => Read(async () => await api.GetAsync("/doctors"));
    /// <summary>Patients by mobile - the same search as B2C Booking (OPD SearchPatientByPhone): from 3 digits, this branch's
    /// patients unless Hospital Settings "Global patient search" is on.</summary>
    [HttpGet]
    public async Task<IActionResult> Patients(string? search)
    {
        search = search?.Trim();
        if (string.IsNullOrEmpty(search) || search.Length < 3) return Json(new { success = true, data = Array.Empty<object>() });
        var branchId = User.GetCurrentBranchId();
        var global = await Microsoft.EntityFrameworkCore.EntityFrameworkQueryableExtensions.AnyAsync(
            dbContext.HospitalSettings, s => s.BranchId == branchId && s.GlobalPatientSearchRequired == true);
        var rows = await patientService.SearchByPhoneAsync(search, global ? null : branchId);
        return Json(new { success = true, data = rows.Select(p => new { p.PatientId, p.PatientCode, p.FullName, p.PhoneNumber, p.Gender, p.RelationName, p.BloodGroup, p.DateOfBirth }) });
    }

    /// <summary>The chosen patient's details to fill the form (as B2C Booking's populatePatient).</summary>
    [HttpGet]
    public async Task<IActionResult> Patient(int id)
    {
        var p = await patientService.GetByIdAsync(id);
        if (p is null) return Fail("The patient was not found.");
        int? age = p.DateOfBirth is DateTime dob ? EMR.Web.Utils.AgeCalculator.FromDateOfBirth(dob).Item1 : null;
        return Json(new { success = true, data = new { p.PatientId, p.PatientCode, p.Salutation, p.FirstName, p.LastName, p.PhoneNumber, p.EmailId, p.Gender, AgeYears = age } });
    }

    // ── simulate / generate ────────────────────────────────────────────────────────────────────────────────
    public sealed class ItemBody { public string Kind { get; set; } = "T"; public int Id { get; set; } public int Qty { get; set; } = 1; }
    public sealed class DeptBody { public string Key { get; set; } = ""; public string Type { get; set; } = "P"; public decimal Value { get; set; } }
    public class CalcBody
    {
        public List<ItemBody> Items { get; set; } = new();
        public string? DiscType { get; set; }
        public decimal DiscValue { get; set; }
        public List<DeptBody>? DeptDisc { get; set; }
        public int? PatientId { get; set; }
        public bool HasDiscount => DiscType == "D" ? DeptDisc?.Any(d => d.Value > 0) == true : DiscType is "P" or "F" && DiscValue > 0;
    }
    public sealed class SaveBody : CalcBody
    {
        public string? Salutation { get; set; }
        public string? PatientName { get; set; }
        public string? Gender { get; set; }
        public int? AgeYears { get; set; }
        public string? Mobile { get; set; }
        public string? EmailId { get; set; }
        public int? RefDoctorId { get; set; }
        public int ValidDays { get; set; } = 7;
        public string? Remarks { get; set; }
    }
    private static string ItemsJson(CalcBody b) => JsonSerializer.Serialize(b.Items.Select(i => new { kind = i.Kind, id = i.Id, qty = i.Qty }));
    private static string? DeptJson(CalcBody b) => b.DiscType == "D" && b.DeptDisc is { Count: > 0 } d ? JsonSerializer.Serialize(d.Select(x => new { key = x.Key, type = x.Type, value = x.Value })) : null;

    /// <summary>Works out the estimate on the server (nothing saved). A discount needs the DISCOUNT right.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Calc([FromBody] CalcBody b)
    {
        if (b.HasDiscount && !await Can("DISCOUNT")) return Fail("You do not have permission to give a discount on the estimate.");
        return await Read(async () => await api.PostAsync("/calc", new { BranchId = Branch, Items = ItemsJson(b), b.DiscType, b.DiscValue, DeptDisc = DeptJson(b), b.PatientId }));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] SaveBody b)
    {
        if (Branch <= 0) return Fail("Your branch could not be found - sign in again.");
        var canDiscount = await Can("DISCOUNT");
        if (b.HasDiscount && !canDiscount) return Fail("You do not have permission to give a discount on the estimate.");
        try
        {
            var row = await api.PostAsync("", new
            {
                BranchId = Branch, b.PatientId, b.Salutation, b.PatientName, b.Gender, b.AgeYears, b.Mobile, b.EmailId, b.RefDoctorId,
                Items = ItemsJson(b), b.DiscType, b.DiscValue, DeptDisc = DeptJson(b), CanDiscount = canDiscount, b.ValidDays, b.Remarks
            });
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The estimate could not be saved.");
            await auditLogService.LogActivityAsync(eventType: "LAB", actionName: "LabEstimate.Generate",
                description: $"B2C bill estimate {row.S("EstimateNo")} for {b.PatientName} ({b.Mobile}): Rs {row.D("NetAmount"):0.00}",
                userId: User.GetUserId(), branchId: Branch, moduleCode: "LAB", referenceId: row.I("EstimateId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Estimate API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    // ── list / view / print ────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> List(DateTime fromDate, DateTime toDate, string? search, string? status) =>
        Read(async () => await api.GetAsync(IpdApiClient.Q(("branchId", Branch.ToString()), ("fromDate", fromDate.ToString("yyyy-MM-dd")),
            ("toDate", toDate.ToString("yyyy-MM-dd")), ("search", search), ("status", status))));

    [HttpGet]
    public Task<IActionResult> Get(int id) => Read(async () => await api.GetAsync($"/{id}" + IpdApiClient.Q(("branchId", Branch.ToString()))));

    private async Task<LabEstimateDoc?> LoadAsync(int id) => LabEstimateDoc.From(await api.GetAsync($"/{id}" + IpdApiClient.Q(("branchId", Branch.ToString()))));
    private async Task<LabEstimateDoc?> LoadPublicAsync(Guid token) => LabEstimateDoc.From(await api.GetAsync($"/public/{token}"));
    private string PublicUrl(string action, Guid token) => $"{Request.Scheme}://{Request.Host}{Request.PathBase}/LabEstimate/{action}?t={token}";

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var d = await LoadAsync(id);
        if (d is null) return NotFound("Estimate not found in your branch.");
        ViewData["PdfUrl"] = Url.Action("Pdf", new { id });
        return View("Print", d);
    }

    [HttpGet]
    public async Task<IActionResult> Pdf(int id)
    {
        var d = await LoadAsync(id);
        if (d is null) return NotFound("Estimate not found in your branch.");
        return File(LabEstimatePdf.Build(d), "application/pdf", $"Estimate_{d.EstimateNo.Replace('/', '-')}.pdf");
    }

    /// <summary>The link sent to the patient: the estimate without sign-in, by its unguessable token.</summary>
    [AllowAnonymous, HttpGet("/LabEstimate/View")]
    public async Task<IActionResult> PublicView(Guid t)
    {
        if (t == Guid.Empty) return NotFound();
        try
        {
            var d = await LoadPublicAsync(t);
            if (d is null) return NotFound("This estimate link is not valid.");
            ViewData["PdfUrl"] = Url.Action("PublicPdf", new { t });
            ViewData["Public"] = true;
            return View("Print", d);
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { logger.LogWarning(ex, "Public estimate {Token}", t); return NotFound("This estimate link is not valid."); }
    }

    [AllowAnonymous, HttpGet]
    public async Task<IActionResult> PublicPdf(Guid t)
    {
        if (t == Guid.Empty) return NotFound();
        try
        {
            var d = await LoadPublicAsync(t);
            if (d is null) return NotFound();
            return File(LabEstimatePdf.Build(d), "application/pdf", $"Estimate_{d.EstimateNo.Replace('/', '-')}.pdf");
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { logger.LogWarning(ex, "Public estimate PDF {Token}", t); return NotFound(); }
    }

    // ── send / cancel ──────────────────────────────────────────────────────────────────────────────────────
    public sealed class SendBody { public string? Mobile { get; set; } }

    /// <summary>WhatsApp to the patient's mobile (or another number typed on the screen): the estimate PDF and its link.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Send(int id, [FromBody] SendBody? b)
    {
        try
        {
            var d = await LoadAsync(id);
            if (d is null) return Fail("Estimate not found in your branch.");
            if (d.Status == "CANCELLED") return Fail("A cancelled estimate cannot be sent.");
            var to = (string.IsNullOrWhiteSpace(b?.Mobile) ? d.Mobile : b!.Mobile!).Trim();
            if (to.Length != 10 || !to.All(char.IsDigit) || to[0] < '6') return Fail("Enter a valid 10-digit mobile number (starting with 6, 7, 8 or 9).");
            // as the LAB bill on WhatsApp (TriggerLabBillWhatsAppAsync): the PDF is uploaded to the WhatsApp provider and sent as
            // an attachment from the provider's own URL - it does not depend on this server being reachable from the internet
            var pdf = LabEstimatePdf.Build(d);
            var documentUrl = await whatsApp.UploadMediaAsync(pdf, "application/pdf", d.BranchId);
            if (string.IsNullOrWhiteSpace(documentUrl))
                return Fail("Not sent: the estimate PDF could not be uploaded to WhatsApp (check the branch's WhatsApp configuration).");
            // the view link only when this server is reachable from outside (not on localhost / an internal address)
            var host = Request.Host.Host;
            var isLocal = host is "localhost" or "127.0.0.1" or "::1" || host.StartsWith("192.168.") || host.StartsWith("10.") || host.EndsWith(".local");
            var text = $"Dear {d.PatientName},\nPlease find attached the estimate for your lab tests at {d.BranchName}.\nEstimate No: {d.EstimateNo}\n"
                     + $"Tests: {d.Lines.Count(l => l.ItemKind != "M")}\nEstimated amount: Rs {d.NetAmount:N2}\nValid till: {d.ValidTill:dd-MMM-yyyy}\n"
                     + (isLocal ? "" : $"\nView online: {PublicUrl("View", d.PublicToken)}\n")
                     + "\nThis is an estimate, not a bill.";
            var res = await whatsApp.SendTextMessageAsync(to, text, d.BranchId, "LAB_ESTIMATE", d.EstimateId,
                documentUrl, $"Estimate_{d.EstimateNo.Replace('/', '-')}.pdf");
            if (!res.Success) return Fail("Not sent: " + (res.ErrorMessage ?? "WhatsApp is not available for this branch."));
            await api.PostAsync($"/{id}/sent", new { BranchId = Branch, SentTo = to });
            await auditLogService.LogActivityAsync(eventType: "LAB", actionName: "LabEstimate.Send", description: $"Estimate {d.EstimateNo} sent to {to} on WhatsApp",
                userId: User.GetUserId(), branchId: Branch, moduleCode: "LAB", referenceId: id);
            return Json(new { success = true, data = new { sentTo = to } });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Estimate send failed"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    public sealed class CancelBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, [FromBody] CancelBody? b)
    {
        try
        {
            var row = await api.PostAsync($"/{id}/cancel", new { BranchId = Branch, b?.Reason });
            if (!row.B("Success")) return Fail(row.S("Error") ?? "The estimate could not be cancelled.");
            await auditLogService.LogActivityAsync(eventType: "LAB", actionName: "LabEstimate.Cancel", description: $"Estimate {id} cancelled: {b?.Reason}",
                userId: User.GetUserId(), branchId: Branch, moduleCode: "LAB", referenceId: id);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException) { return Fail("The EMR API is not reachable. Try again in a moment."); }
    }
}
