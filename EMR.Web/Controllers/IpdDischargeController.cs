using System.Text.Json;
using System.Text.RegularExpressions;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 7 - Discharge (SQLScripts/2557, 2558): the Discharge tab of the IPD Patient workspace and IPD > Discharges.
/// Flow: advice -> clearances (pharmacy, LAB, nursing, TPA) -> final bill (Billing tab) -> settlement -> summary signed
/// -> gate pass (bed released to housekeeping) -> OPD follow-up. LAMA / DAMA form and death record (MCCD) by type.
/// Web -> EMR.Api api/ipd -> procedures. Rights the procedures need ("Can...") are worked out here, never taken from the page.
/// </summary>
[Authorize]
public class IpdDischargeController(IpdApiClient api, IDoctorScheduleApiClient schedule, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService,
    IPrintTemplateRuntime printRuntime, IWebHostEnvironment env, ILogger<IpdDischargeController> logger) : Controller
{
    public const string BoardPage = "IPD.DISCHARGES";
    private const string PatientPage = IpdAdmissionController.PatientPage;
    private static readonly Dictionary<string, string> ClearControl = new(StringComparer.OrdinalIgnoreCase)
    {
        ["PHARMACY"] = "CLEAR_PHARMACY", ["LAB"] = "CLEAR_LAB", ["NURSING"] = "CLEAR_NURSING", ["TPA"] = "CLEAR_TPA"
    };

    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string page, string control) => permissionGuard.AllowsAsync(HttpContext, page, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, int refId)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD Discharge", actionName: action, description: description,
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    /// <summary>The page's body as sent, without any "Can..." flag (those are set from the user's rights), plus the extra values.</summary>
    private static Dictionary<string, object?> Body(JsonElement body, params (string Key, object? Value)[] extra)
    {
        var d = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        if (body.ValueKind == JsonValueKind.Object)
            foreach (var p in body.EnumerateObject())
                if (!p.Name.StartsWith("can", StringComparison.OrdinalIgnoreCase)) d[p.Name] = p.Value;
        foreach (var (k, v) in extra) d[k] = v;
        return d;
    }

    private async Task<string?> SaveSignatureAsync(string? dataUrl)
    {
        if (string.IsNullOrWhiteSpace(dataUrl)) return null;
        var m = Regex.Match(dataUrl, "^data:image/png;base64,(?<b>[A-Za-z0-9+/=]+)$");
        if (!m.Success) return null;
        var bytes = Convert.FromBase64String(m.Groups["b"].Value);
        if (bytes.Length == 0 || bytes.Length > 2 * 1024 * 1024) return null;
        var dir = Path.Combine(env.WebRootPath, "uploads", "ipd", "signatures");
        Directory.CreateDirectory(dir);
        var name = $"{Guid.NewGuid()}.png";
        await System.IO.File.WriteAllBytesAsync(Path.Combine(dir, name), bytes);
        return $"/uploads/ipd/signatures/{name}";
    }

    // ── Discharge tab ───────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Data(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/discharge");
        var summaries = s.ElementAtOrDefault(3);
        var followUps = s.ElementAtOrDefault(6);
        var hdr = s.ElementAtOrDefault(0);
        int? patientId = hdr.ValueKind == JsonValueKind.Array && hdr.GetArrayLength() > 0 ? hdr[0].NI("PatientId") : null;
        // page URLs are built here, encrypted (CLAUDE.md): prints and the OPD booking of a follow-up
        var prints = new
        {
            summary = Url.ActionEncrypted("PrintSummary", "IpdDischarge", new { id }),
            lama = Url.ActionEncrypted("PrintLama", "IpdDischarge", new { id }),
            death = Url.ActionEncrypted("PrintDeath", "IpdDischarge", new { id }),
            gatePass = Url.ActionEncrypted("PrintGatePass", "IpdDischarge", new { id }),
            versions = summaries.ValueKind == JsonValueKind.Array
                ? summaries.EnumerateArray().ToDictionary(v => v.I("SummaryId").ToString(), v => Url.ActionEncrypted("PrintSummary", "IpdDischarge", new { id, summaryId = v.I("SummaryId") }))
                : new Dictionary<string, string>()
        };
        var opd = followUps.ValueKind == JsonValueKind.Array
            ? followUps.EnumerateArray().Where(f => f.S("Status") == "BOOKED").ToDictionary(f => f.I("FollowUpId").ToString(), f => Url.ActionEncrypted("NewServiceBooking", "OPD", new
              {
                  patientId, followUpId = f.I("FollowUpId"), doctorId = f.I("DoctorId"), date = f.D("FollowUpDate")?.ToString("yyyy-MM-dd"),
                  scheduleId = f.NI("ScheduleId"), time = f.S("SlotTime") is { Length: > 0 } t ? t : null
              }))
            : new Dictionary<string, string>();
        return new
        {
            header = s.ElementAtOrDefault(0), discharge = s.ElementAtOrDefault(1), clearances = s.ElementAtOrDefault(2), summaries, lama = s.ElementAtOrDefault(4),
            death = s.ElementAtOrDefault(5), followUps, labPending = s.ElementAtOrDefault(7), doctors = s.ElementAtOrDefault(8), prints, opd
        };
    });

    [HttpGet]
    public Task<IActionResult> Prefill(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/discharge/prefill");
        return new { admission = s.ElementAtOrDefault(0), procedures = s.ElementAtOrDefault(1), investigations = s.ElementAtOrDefault(2), medicines = s.ElementAtOrDefault(3) };
    });

    /// <summary>Medicine search for the summary's "Medicines on discharge" (Master > EMR Medication).</summary>
    [HttpGet]
    public Task<IActionResult> Medicines(string? q) => Read(async () => await api.GetAsync("/discharge/medicines" + IpdApiClient.Q(("q", q))));

    /// <summary>Free slots of a doctor's OPD roster on a date (the follow-up picker).</summary>
    [HttpGet]
    public async Task<IActionResult> Slots(int doctorId, DateTime date)
    {
        try
        {
            var r = await schedule.GetAvailableSlotsAsync(doctorId, User.GetCurrentBranchId() ?? 0, date.Date);
            return Json(new { success = true, data = new { hasException = r?.HasException ?? false, exceptionReason = r?.ExceptionReason, slots = r?.Slots ?? [] } });
        }
        catch (Exception ex) { logger.LogWarning(ex, "Doctor roster slots"); return Fail("The doctor's roster could not be read."); }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Advise(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "DISCHARGE_ADVISE")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/advise", Body(b)), "IPD.DischargeAdvise", $"Admission {id}: discharge advised ({b.S("dischargeType")})", id);
    }

    public sealed class ReasonBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelAdvice(int id, [FromBody] ReasonBody b)
    {
        if (!await Can(PatientPage, "DISCHARGE_ADVISE")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/cancel", new { b.Reason }), "IPD.DischargeAdviceCancel", $"Admission {id}: discharge advice cancelled: {b.Reason}", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Clear(int id, [FromBody] JsonElement b)
    {
        var dept = b.S("dept") ?? "";
        if (!ClearControl.TryGetValue(dept, out var control) || !await Can(PatientPage, control)) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/clear", Body(b)), "IPD.DischargeClearance",
            $"Admission {id}: {dept} clearance {(b.S("action") == "REOPEN" ? "reopened" : "done")}", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveSummary(int id, [FromBody] JsonElement b)
    {
        var canSign = await Can(PatientPage, "DISCHARGE_SUMMARY_SIGN");
        var canOnBehalf = await Can(PatientPage, "DISCHARGE_SUMMARY_ONBEHALF");
        if (!canSign && !canOnBehalf && !await Can(PatientPage, "DISCHARGE_SUMMARY")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/summary", Body(b, ("CanSign", canSign), ("CanSignOnBehalf", canOnBehalf))), "IPD.DischargeSummary",
            $"Admission {id}: discharge summary {(b.B("sign") ? "signed" : "saved")}"
            + (b.S("onBehalfReason") is { Length: > 0 } ob ? $" on behalf of the consultant ({ob})" : "") + (b.S("amendReason") is { Length: > 0 } r ? $" (amended: {r})" : ""), id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Lama(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "DISCHARGE_LAMA")) return Fail(PermissionFilter.DeniedMessage);
        var extra = new List<(string, object?)>
        {
            ("SignaturePath", await SaveSignatureAsync(b.S("signature"))), ("WitnessSignaturePath", await SaveSignatureAsync(b.S("witnessSignature"))),
            ("DoctorSignaturePath", await SaveSignatureAsync(b.S("doctorSignature"))), ("signature", null), ("witnessSignature", null), ("doctorSignature", null)
        };
        var voided = b.S("voidReason") is { Length: > 0 };
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/lama", Body(b, extra.ToArray())), "IPD.DischargeLama",
            $"Admission {id}: LAMA / DAMA form {(voided ? "voided" : "recorded")}", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Death(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "DEATH_RECORD")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/death", Body(b)), "IPD.DeathRecord",
            $"Admission {id}: death record {(b.S("voidReason") is { Length: > 0 } ? "voided" : "saved")}", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> GatePass(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "GATEPASS")) return Fail(PermissionFilter.DeniedMessage);
        var canCredit = await Can(PatientPage, "GATEPASS_CREDIT");
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/gatepass", Body(b, ("CanCredit", canCredit))), "IPD.GatePass",
            $"Admission {id}: gate pass, patient discharged" + (b.B("credit") ? " (credit discharge)" : ""), id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> FollowUp(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "FOLLOWUP")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/discharge/followup", Body(b)), "IPD.FollowUp",
            $"Admission {id}: OPD follow-up {(b.S("cancelReason") is { Length: > 0 } ? "cancelled" : "booked")}", id);
    }

    // ── prints ─────────────────────────────────────────────────────────────────────────────────────────────────
    private async Task<IActionResult> PrintAsync(int id, int? summaryId, string kind, string title)
    {
        try
        {
            var s = await api.SetsAsync($"/admissions/{id}/discharge/print" + IpdApiClient.Q(("summaryId", summaryId)));
            var header = s.ElementAtOrDefault(0);
            if (header.ValueKind != JsonValueKind.Array || header.GetArrayLength() == 0) return NotFound();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, User.GetCurrentBranchId() ?? 0,
                new PrintDocInfo { DocNo = header[0].S("IpNo"), DocDate = DateTime.Now.ToString("dd-MMM-yyyy HH:mm"), CopyLabel = "Original", PrintedBy = this.PrintedBy() });
            var sum = s.ElementAtOrDefault(1);
            var sumStatus = sum.ValueKind == JsonValueKind.Array && sum.GetArrayLength() > 0 ? sum[0].S("Status") : "";
            var death = sum.ValueKind == JsonValueKind.Array && sum.GetArrayLength() > 0 && sum[0].S("SummaryType") == "DEATH";
            ViewData["DocTitle"] = kind == "summary" && death ? "Death Summary" : title;
            if (kind == "gatepass") ViewData["PageSize"] = "A5 landscape";
            if (kind == "summary" && sumStatus != "SIGNED") ViewData["Watermark"] = sumStatus == "SUPERSEDED" ? "SUPERSEDED" : "DRAFT";
            ViewData["Print"] = JsonSerializer.Serialize(new
            {
                kind, header = header[0], summary = s.ElementAtOrDefault(1), discharge = s.ElementAtOrDefault(2), lama = s.ElementAtOrDefault(3), death = s.ElementAtOrDefault(4),
                followUps = s.ElementAtOrDefault(5), bill = s.ElementAtOrDefault(6), hospital = ViewBag.PrintHospital, printedBy = this.PrintedBy(), printedAt = DateTime.Now,
                // the signing doctor's image (Doctor Master, SQLScripts/2559): only for a signed summary / a death record, through a protected link
                signUrls = new
                {
                    summary = sumStatus == "SIGNED" && sum[0].B("SignedByHasSignature") ? Url.ActionEncrypted("DoctorSignature", "IpdDischarge", new { id, kind = "summary", summaryId = sum[0].I("SummaryId") }) : null,
                    death = s.ElementAtOrDefault(4) is { ValueKind: JsonValueKind.Array } dr && dr.GetArrayLength() > 0 && dr[0].B("CertifiedByHasSignature")
                        ? Url.ActionEncrypted("DoctorSignature", "IpdDischarge", new { id, kind = "death" }) : null
                }
            });
            return View("Print");
        }
        catch (HttpRequestException) { ViewData["PageName"] = title; return View("ApiDown"); }
        catch (InvalidOperationException ex) { return Content(ex.Message); }
    }

    [HttpGet] public Task<IActionResult> PrintSummary(int id, int? summaryId) => PrintAsync(id, summaryId, "summary", "Discharge Summary");
    [HttpGet] public Task<IActionResult> PrintLama(int id) => PrintAsync(id, null, "lama", "Leaving Against Medical Advice");
    [HttpGet] public Task<IActionResult> PrintDeath(int id) => PrintAsync(id, null, "death", "Medical Certificate of Cause of Death");
    [HttpGet] public Task<IActionResult> PrintGatePass(int id) => PrintAsync(id, null, "gatepass", "Gate Pass");

    /// <summary>
    /// The signature image of the doctor who signed this admission's summary (kind = summary) or certified its death (kind = death).
    /// Only that doctor's image can be read here, never any other doctor's.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> DoctorSignature(int id, string kind, int? summaryId, [FromServices] DoctorSignatureApiClient signatures)
    {
        try
        {
            var s = await api.SetsAsync($"/admissions/{id}/discharge/print" + IpdApiClient.Q(("summaryId", summaryId)));
            int? doctorId = null;
            if (kind == "summary" && s.ElementAtOrDefault(1) is { ValueKind: JsonValueKind.Array } sm && sm.GetArrayLength() > 0 && sm[0].S("Status") == "SIGNED")
                doctorId = sm[0].NI("SignedByDoctorId");
            else if (kind == "death" && s.ElementAtOrDefault(4) is { ValueKind: JsonValueKind.Array } dr && dr.GetArrayLength() > 0)
                doctorId = dr[0].NI("CertifiedByDoctorId");
            if (doctorId is not > 0) return NotFound();
            var f = DoctorSignatureStore.Find(env, await signatures.GetAsync(doctorId.Value));
            if (f is null) return NotFound();
            Response.Headers.CacheControl = "no-store";
            return PhysicalFile(f.Value.Path, f.Value.ContentType);
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException) { return NotFound(); }
    }

    // ── IPD > Discharges ───────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Board()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewData["CanPatient"] = await Can(PatientPage, "VIEW");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> BoardData(DateTime? from, DateTime? to, string? type, string? search) => Read(async () =>
    {
        var s = await api.SetsAsync("/discharges" + IpdApiClient.Q(("from", from?.ToString("yyyy-MM-dd")), ("to", to?.ToString("yyyy-MM-dd")), ("type", type), ("search", search)));
        object Rows(JsonElement set) => set.ValueKind != JsonValueKind.Array ? Array.Empty<object>() : set.EnumerateArray().Select(r => new
        {
            row = r,
            open = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId"), tab = "discharge" }),
            summary = Url.ActionEncrypted("PrintSummary", "IpdDischarge", new { id = r.I("AdmissionId") }),
            mccd = Url.ActionEncrypted("PrintDeath", "IpdDischarge", new { id = r.I("AdmissionId") })
        }).ToList();
        return new { progress = Rows(s.ElementAtOrDefault(0)), discharged = Rows(s.ElementAtOrDefault(1)), kpi = s.ElementAtOrDefault(2), deaths = Rows(s.ElementAtOrDefault(3)) };
    });
}
