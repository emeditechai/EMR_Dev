using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD flow-gap fixes (SQLScripts/2570-2576) on the IPD Patient workspace and two pages:
/// interim bill, supplementary bill / credit note, reopen a gate pass, allergy status, code status, isolation, medicine alerts,
/// pharmacist verification, escalations, medication reconciliation, record gaps, transfusion, restraint, newborn link;
/// IPD > Credit Dues (IPD.CREDITDUES) and IPD > Medicine Verification (IPD.MEDVERIFY).
/// Rights are the controls of IPD.PATIENT (SQLScripts/2576); the procedures check every rule again. Web -> EMR.Api api/ipd -> procedures.
/// Page URLs are built here, encrypted (CLAUDE.md).
/// </summary>
[Authorize]
public class IpdGapsController(IpdApiClient api, IActionPermissionGuard permissionGuard, IPrintTemplateRuntime printRuntime,
    IAuditLogService auditLogService, ILogger<IpdGapsController> logger) : Controller
{
    public const string CreditDuesPage = "IPD.CREDITDUES";
    public const string VerifyPage = "IPD.MEDVERIFY";
    private const string PatientPage = IpdAdmissionController.PatientPage;

    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string control, string page = PatientPage) => permissionGuard.AllowsAsync(HttpContext, page, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(string? control, Func<Task<JsonElement>> call, string action, string description, int? refId, string page = PatientPage)
    {
        if (control is not null && !await Can(control, page)) return Fail(PermissionFilter.DeniedMessage);
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    /// <summary>The page's body as sent, without any "Can..." flag.</summary>
    private static Dictionary<string, object?> Body(JsonElement body)
    {
        var d = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        if (body.ValueKind == JsonValueKind.Object)
            foreach (var p in body.EnumerateObject())
                if (!p.Name.StartsWith("can", StringComparison.OrdinalIgnoreCase)) d[p.Name] = p.Value;
        return d;
    }

    private static string? Str(JsonElement b, string name) =>
        b.ValueKind == JsonValueKind.Object && b.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    // ── billing ────────────────────────────────────────────────────────────────────────────────────────────────
    /// <summary>A5: the running bill as an interim bill (same print as the final bill, marked INTERIM).</summary>
    [HttpGet]
    public async Task<IActionResult> InterimBill(int id, string? format)
    {
        try
        {
            var s = await api.SetsAsync($"/admissions/{id}/interim-bill");
            var bill = s.First(0); var header = s.First(1);
            if (!bill.Has() || !header.Has() || bill.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, bill.I("BranchId"), new PrintDocInfo
                { DocNo = "INTERIM · " + header.S("IpNo"), DocDate = bill.Dt("BillAt"), CopyLabel = "Interim", PrintedBy = this.PrintedBy() });
            ViewData["Watermark"] = "INTERIM BILL";
            return View("~/Views/IpdBilling/PrintBill.cshtml", new IpdPrintView
            {
                Title = "IPD Interim Bill (not a final bill)", DocNo = "INTERIM", Header = header, Doc = bill, Rows = s.ElementAtOrDefault(2).Items(),
                Rows2 = s.ElementAtOrDefault(3).Items(), Totals = s.ElementAtOrDefault(4), Format = format == "detail" ? "detail" : "summary", PrintedBy = this.PrintedBy()
            });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "IPD Interim Bill"; return View("ApiDown"); }
    }

    [HttpGet]
    public Task<IActionResult> BillAdjustments(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/bill-adjustments");
        var docs = s.ElementAtOrDefault(0);
        var prints = docs.ValueKind == JsonValueKind.Array
            ? docs.EnumerateArray().ToDictionary(d => d.I("AdjId").ToString(), d => Url.ActionEncrypted("PrintBillAdjustment", "IpdGaps", new { id = d.I("AdjId") }))
            : new Dictionary<string, string>();
        return new { docs, balance = s.ElementAtOrDefault(1), billLines = s.ElementAtOrDefault(2), prints };
    });

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveBillAdjustment(int id, [FromBody] JsonElement b) =>
        Write("BILL_ADJUST", () => api.PostAsync($"/admissions/{id}/bill-adjustments", new { Kind = Str(b, "kind"), Lines = Str(b, "lines") ?? "[]", Reason = Str(b, "reason") }),
            "IPD.BillAdjustment", $"Admission {id}: {(Str(b, "kind") == "CRED" ? "credit note" : "supplementary bill")} - {Str(b, "reason")}", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> CancelBillAdjustment(int adjId, [FromBody] JsonElement b) =>
        Write("BILL_ADJUST_CANCEL", () => api.PostAsync($"/bill-adjustments/{adjId}/cancel", new { Reason = Str(b, "reason") }),
            "IPD.BillAdjustmentCancel", $"Supplementary bill / credit note {adjId} cancelled: {Str(b, "reason")}", adjId);

    [HttpGet]
    public async Task<IActionResult> PrintBillAdjustment(int id)
    {
        try
        {
            var s = await api.SetsAsync($"/bill-adjustments/{id}");
            var doc = s.First(0); var header = s.First(1);
            if (!doc.Has() || !header.Has() || doc.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            var credit = doc.S("Kind") == "CRED";
            await IpdPrint.PrepareAsync(this, printRuntime, logger, doc.I("BranchId"), new PrintDocInfo
                { DocNo = doc.S("DocNo"), DocDate = doc.Dt("DocAt"), CopyLabel = doc.S("Status") == "CANCELLED" ? "Cancelled" : "Original", PrintedBy = this.PrintedBy() });
            if (doc.S("Status") == "CANCELLED") ViewData["Watermark"] = "CANCELLED";
            return View("PrintBillAdjustment", new IpdPrintView
            {
                Title = credit ? "IPD Credit Note" : "IPD Supplementary Bill", DocNo = doc.S("DocNo"), Header = header, Doc = doc, Rows = s.ElementAtOrDefault(2).Items(),
                Rows2 = new List<JsonElement>(), Totals = default, Format = "detail", PrintedBy = this.PrintedBy()
            });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "IPD Bill Adjustment"; return View("ApiDown"); }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> ReopenDischarge(int id, [FromBody] JsonElement b) =>
        Write("DISCHARGE_REOPEN", () => api.PostAsync($"/admissions/{id}/discharge/reopen", new { Reason = Str(b, "reason") }),
            "IPD.DischargeReopen", $"Admission {id}: gate pass reopened - {Str(b, "reason")}", id);

    // ── IPD > Credit Dues ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult CreditDues()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> CreditDuesData(string? search) => Read(async () =>
    {
        var rows = await api.GetAsync("/credit-dues" + IpdApiClient.Q(("search", search)));
        return rows.ValueKind != JsonValueKind.Array ? Array.Empty<object>() : rows.EnumerateArray().Select(r => (object)new
        {
            row = r,
            open = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId"), tab = "billing" })
        }).ToList();
    });

    // ── safety ─────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> MedCheck(int id, int? itemId, string? drugName) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/med-check" + IpdApiClient.Q(("itemId", itemId), ("drugName", drugName)));
        return new { allergy = s.First(0), alerts = s.ElementAtOrDefault(1) };
    });

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveAllergy(int id, [FromBody] JsonElement b) =>
        Write("ALLERGY", () => api.PostAsync($"/admissions/{id}/allergy", Body(b)), "IPD.Allergy", $"Admission {id}: allergy status recorded", id);

    [HttpGet]
    public Task<IActionResult> CodeStatus(int id) => Read(async () => await api.GetAsync($"/admissions/{id}/code-status"));

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveCodeStatus(int id, [FromBody] JsonElement b) =>
        Write("CODE_STATUS", () => api.PostAsync($"/admissions/{id}/code-status", Body(b)), "IPD.CodeStatus", $"Admission {id}: code status {Str(b, "codeStatus")}", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveIsolation(int id, [FromBody] JsonElement b) =>
        Write("ISOLATION", () => api.PostAsync($"/admissions/{id}/isolation", Body(b)), "IPD.Isolation", $"Admission {id}: isolation {Str(b, "isolationType") ?? "ended"}", id);

    // ── pharmacist verification ────────────────────────────────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> VerifyOrder(int orderId, [FromBody] JsonElement b) =>
        Write("ORDER_VERIFY", () => api.PostAsync($"/orders/{orderId}/verify", Body(b)), "IPD.OrderVerify", $"Order {orderId}: {Str(b, "action") ?? "VERIFY"} {Str(b, "note")}", orderId);

    [HttpGet]
    public async Task<IActionResult> VerifyQueue()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewData["CanVerify"] = await Can("VERIFY", VerifyPage);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> VerifyQueueData(int? admissionId) => Read(async () =>
    {
        var rows = await api.GetAsync("/orders/verify-queue" + IpdApiClient.Q(("admissionId", admissionId)));
        return rows.ValueKind != JsonValueKind.Array ? Array.Empty<object>() : rows.EnumerateArray().Select(r => (object)new
        {
            row = r,
            open = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId"), tab = "indent" })
        }).ToList();
    });

    /// <summary>Verification from IPD > Medicine Verification (its own VERIFY control).</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> QueueVerify(int orderId, [FromBody] JsonElement b) =>
        Write("VERIFY", () => api.PostAsync($"/orders/{orderId}/verify", Body(b)), "IPD.OrderVerify", $"Order {orderId}: {Str(b, "action") ?? "VERIFY"} {Str(b, "note")}", orderId, VerifyPage);

    // ── escalations ────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Escalations(int id) => Read(async () => await api.GetAsync($"/admissions/{id}/escalations"));

    [HttpGet]
    public Task<IActionResult> OpenEscalations() => Read(async () =>
    {
        var rows = await api.GetAsync("/escalations");
        return rows.ValueKind != JsonValueKind.Array ? Array.Empty<object>() : rows.EnumerateArray().Select(r => (object)new
        {
            row = r,
            open = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId"), tab = "nursing" })
        }).ToList();
    });

    /// <summary>RAISE / CLOSE need ESCALATE; ACK (the doctor's response) needs ESCALATION_ACK.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> EscalationAction(int id, [FromBody] JsonElement b)
    {
        var action = (Str(b, "action") ?? "").ToUpperInvariant();
        var control = action == "ACK" ? "ESCALATION_ACK" : action is "RAISE" or "CLOSE" ? "ESCALATE" : null;
        if (control is null) return Fail("Unknown escalation action.");
        return await Write(control, () => api.PostAsync($"/admissions/{id}/escalations", Body(b)), "IPD.Escalation", $"Admission {id}: escalation {action} {Str(b, "text")}", id);
    }

    // ── medication reconciliation, record gaps ─────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> MedRecon(int id) => Read(async () => await api.GetAsync($"/admissions/{id}/med-recon"));

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveMedRecon(int id, [FromBody] JsonElement b) =>
        Write("MED_RECON", () => api.PostAsync($"/admissions/{id}/med-recon", Body(b)), "IPD.MedRecon", $"Admission {id}: {Str(b, "stage")} medication reconciliation", id);

    [HttpGet]
    public Task<IActionResult> RecordGaps(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/record-gaps");
        return new { gaps = s.ElementAtOrDefault(0), blockers = s.ElementAtOrDefault(1) };
    });

    // ── transfusion, restraint, newborn ────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Safety(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/safety");
        var babies = s.ElementAtOrDefault(4);
        var mother = s.ElementAtOrDefault(3);
        var links = new Dictionary<string, string>();
        foreach (var r in babies.Items()) links["baby" + r.I("AdmissionId")] = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("AdmissionId") });
        foreach (var r in mother.Items()) links["mother"] = Url.ActionEncrypted("Patient", "IpdAdmission", new { id = r.I("MotherAdmissionId") });
        return new { transfusions = s.ElementAtOrDefault(0), restraints = s.ElementAtOrDefault(1), checks = s.ElementAtOrDefault(2), mother, babies, links };
    });

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveTransfusion(int id, [FromBody] JsonElement b) =>
        Write("TRANSFUSION", () => api.PostAsync($"/admissions/{id}/transfusion", Body(b)), "IPD.Transfusion", $"Admission {id}: transfusion {Str(b, "action")}", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> SaveRestraint(int id, [FromBody] JsonElement b) =>
        Write("RESTRAINT", () => api.PostAsync($"/admissions/{id}/restraint", Body(b)), "IPD.Restraint", $"Admission {id}: restraint {Str(b, "action")}", id);

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> LinkNewborn(int id, [FromBody] JsonElement b) =>
        Write("NEWBORN", () => api.PostAsync($"/admissions/{id}/newborn", Body(b)), "IPD.Newborn", $"Admission {id}: newborn linked to {Str(b, "motherIpNo")}", id);
}
