using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 6 - pre-authorisation (SQLScripts/2539-2542): the Insurance / TPA tab of the IPD Patient workspace and
/// IPD > Pre-Authorisations (worklist with the IRDAI clock). Writes need IPD.PATIENT control PREAUTH (also from the worklist).
/// Web -> EMR.Api api/ipd -> procedures.
/// </summary>
[Authorize]
public class IpdInsuranceController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, IWebHostEnvironment env,
    ILogger<IpdInsuranceController> logger) : Controller
{
    public const string WorklistPage = "IPD.PREAUTHS";
    private const string PatientPage = IpdAdmissionController.PatientPage;

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
            await auditLogService.LogActivityAsync(eventType: "IPD TPA", actionName: action, description: description,
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
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

    private string PatientTabUrl(int admissionId) => Url.ActionEncrypted("Patient", "IpdAdmission", new { id = admissionId, tab = "insurance" });

    // ── IPD > Pre-Authorisations ─────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> PreAuths()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewData["CanRecord"] = await Can(PatientPage, "PREAUTH");
        ViewData["CanPatient"] = await Can(PatientPage, "VIEW");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> PreAuthList(string? view, int? insuranceTpaId, string? search, DateTime? fromDate, DateTime? toDate) => Read(async () =>
    {
        var q = new List<string> { "view=" + Uri.EscapeDataString(view ?? "OPEN") };
        if (insuranceTpaId is > 0) q.Add("insuranceTpaId=" + insuranceTpaId);
        if (!string.IsNullOrWhiteSpace(search)) q.Add("search=" + Uri.EscapeDataString(search.Trim()));
        if (fromDate is not null) q.Add("fromDate=" + fromDate.Value.ToString("yyyy-MM-dd"));
        if (toDate is not null) q.Add("toDate=" + toDate.Value.ToString("yyyy-MM-dd"));
        var sets = await api.SetsAsync("/preauth?" + string.Join("&", q));
        var rows = sets.ElementAtOrDefault(0).Items();
        var lookups = await api.SetsAsync("/insurance/lookups");
        return new
        {
            rows, kpi = sets.First(1), tpas = lookups.ElementAtOrDefault(0).Items(),
            links = rows.Select(r => r.I("AdmissionId")).Distinct().ToDictionary(id => id.ToString(), PatientTabUrl)
        };
    });

    // ── IPD Patient > Insurance / TPA ────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> TabData(int id) => Read(async () =>
    {
        var sets = await api.SetsAsync($"/admissions/{id}/insurance");
        return new
        {
            admission = sets.First(0), preAuths = sets.ElementAtOrDefault(1).Items(), events = sets.ElementAtOrDefault(2).Items(),
            checklist = sets.ElementAtOrDefault(3).Items(), claims = sets.ElementAtOrDefault(4).Items(),
            claimsUrl = Url.Action("Index", "IpdClaims")
        };
    });

    [HttpGet]
    public Task<IActionResult> Lookups() => Read(async () =>
    {
        var sets = await api.SetsAsync("/insurance/lookups");
        return new { tpas = sets.ElementAtOrDefault(0).Items(), modes = sets.ElementAtOrDefault(1).Items(), docTypes = sets.ElementAtOrDefault(2).Items() };
    });

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePreAuth(int id, [FromBody] JsonElement body)
    {
        if (!await Can(PatientPage, "PREAUTH")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/preauth", Body(body)), "IPD.PreAuthSave", $"Admission {id}: pre-authorisation saved", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> PreAuthEvent(int preAuthId, [FromBody] JsonElement body)
    {
        if (!await Can(PatientPage, "PREAUTH")) return Fail(PermissionFilter.DeniedMessage);
        var step = body.ValueKind == JsonValueKind.Object && body.TryGetProperty("eventType", out var e) ? e.GetString() : null;
        return await Write(() => api.PostAsync($"/preauth/{preAuthId}/event", Body(body)), "IPD.PreAuthEvent", $"Pre-authorisation {preAuthId}: {step}", preAuthId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveSplit(int preAuthId, [FromBody] JsonElement body)
    {
        if (!await Can(PatientPage, "PREAUTH")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/preauth/{preAuthId}/split", Body(body)), "IPD.PreAuthSplit", $"Pre-authorisation {preAuthId}: patient share set", preAuthId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Checklist([FromBody] JsonElement body)
    {
        if (!await Can(PatientPage, "PREAUTH")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync("/insurance/checklist", Body(body)), "IPD.PreAuthChecklist", "Pre-authorisation checklist", 0);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadDocument(int id, IFormFile? file, [FromForm] int? preAuthId, [FromForm] int? docTypeId, [FromForm] string? title, [FromForm] string? remarks)
    {
        if (!await Can(PatientPage, "PREAUTH")) return Fail(PermissionFilter.DeniedMessage);
        string? path;
        try { path = await IpdUploads.SaveAsync(env, file, "ipd/tpa", IpdUploads.Documents); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        if (path is null) return Fail("Choose the file to upload.");
        return await Write(() => api.PostAsync($"/admissions/{id}/tpa-documents", new { PreAuthId = preAuthId, ClaimId = (int?)null, DocTypeId = docTypeId, Title = title, FilePath = path, Remarks = remarks }),
            "IPD.TpaDocument", $"Admission {id}: pre-authorisation document uploaded", id);
    }
}
