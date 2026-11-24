using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 6 - TPA claims (SQLScripts/2539-2542): IPD > TPA Claims (documents, submission, queries, settlements with TDS and
/// disallowance, settlement cancel, write-off approval), IPD > TPA Receivable &amp; Ageing (ageing, TPA statement) and
/// Master > IPD Master > TPA Document Checklist. Write-offs: the Approval Matrix module IPD.TPAWRITEOFF names the approvers
/// for the branch (none named: the WRITEOFF_APPROVE control); the person who asked never approves.
/// </summary>
[Authorize]
public class IpdClaimsController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, IWebHostEnvironment env,
    IPharmacyInventoryService approvals, INotificationService notifications, ILogger<IpdClaimsController> logger) : Controller
{
    public const string ClaimsPage = "IPD.TPACLAIMS";
    public const string AgeingPage = "IPD.TPAAGEING";
    public const string DocTypesPage = "MASTER.IPD_TPADOCS";
    private const string WriteOffModule = "IPD.TPAWRITEOFF";

    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string page, string control) => permissionGuard.AllowsAsync(HttpContext, page, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<(IActionResult Result, JsonElement Row)> WriteRow(Func<Task<JsonElement>> call, string action, string description, int refId)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return (Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed."), row);
            await auditLogService.LogActivityAsync(eventType: "IPD TPA", actionName: action, description: description,
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return (Json(new { success = true, data = row }), row);
        }
        catch (InvalidOperationException ex) { return (Fail(ex.Message), default); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return (Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."), default); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, int refId) =>
        (await WriteRow(call, action, description, refId)).Result;

    private static Dictionary<string, object?> Body(JsonElement body)
    {
        var d = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        if (body.ValueKind == JsonValueKind.Object)
            foreach (var p in body.EnumerateObject())
                if (!p.Name.StartsWith("can", StringComparison.OrdinalIgnoreCase)) d[p.Name] = p.Value;
        return d;
    }

    private static string Q(params (string Key, object? Value)[] items) =>
        string.Join("&", items.Where(i => i.Value is not null && !(i.Value is string s && string.IsNullOrWhiteSpace(s)))
            .Select(i => i.Key + "=" + Uri.EscapeDataString(i.Value is DateTime d ? d.ToString("yyyy-MM-dd") : i.Value!.ToString()!.Trim())));

    private string PatientTabUrl(int admissionId) => Url.ActionEncrypted("Patient", "IpdAdmission", new { id = admissionId, tab = "insurance" });

    private async Task<object> LookupsData()
    {
        var sets = await api.SetsAsync("/insurance/lookups");
        return new { tpas = sets.ElementAtOrDefault(0).Items(), modes = sets.ElementAtOrDefault(1).Items(), docTypes = sets.ElementAtOrDefault(2).Items() };
    }

    // ── IPD > TPA Claims ─────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        foreach (var c in new[] { "SUBMIT", "SETTLE", "SETTLE_CANCEL", "WRITEOFF_APPROVE" }) ViewData["Can" + c] = await Can(ClaimsPage, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> Lookups() => Read(LookupsData);

    [HttpGet]
    public Task<IActionResult> ListData(string? status, int? insuranceTpaId, string? search, DateTime? fromDate, DateTime? toDate) => Read(async () =>
    {
        var sets = await api.SetsAsync("/claims?" + Q(("status", status ?? "ACTIVE"), ("insuranceTpaId", insuranceTpaId is > 0 ? insuranceTpaId : null), ("search", search),
            ("fromDate", fromDate), ("toDate", toDate)));
        var rows = sets.ElementAtOrDefault(0).Items();
        return new { rows, kpi = sets.First(1), links = rows.Select(r => r.I("AdmissionId")).Distinct().ToDictionary(id => id.ToString(), PatientTabUrl) };
    });

    [HttpGet]
    public Task<IActionResult> ClaimData(int id) => Read(async () =>
    {
        var sets = await api.SetsAsync($"/claims/{id}");
        var claim = sets.First(0);
        if (!claim.Has()) throw new InvalidOperationException("The claim was not found.");
        var me = User.GetUserId();
        var approvers = await approvals.MatrixApproversAsync(User.GetCompanyId(), WriteOffModule, User.GetCurrentBranchId() ?? 0);
        return new
        {
            claim, checklist = sets.ElementAtOrDefault(1).Items(), events = sets.ElementAtOrDefault(2).Items(), settlements = sets.ElementAtOrDefault(3).Items(),
            writeOffs = sets.ElementAtOrDefault(4).Items(),
            patientUrl = PatientTabUrl(claim.I("AdmissionId")),
            billUrl = Url.Action("PrintBill", "IpdBilling", new { id = claim.I("BillId") }),
            me, matrix = approvers.Count > 0, canApproveHere = approvers.Count == 0 || approvers.Contains(me) || User.IsSuperAdmin()
        };
    });

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> UpdateClaim(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SUBMIT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/claims/{id}/update", Body(body)), "IPD.ClaimUpdate", $"Claim {id}: details saved", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Submit(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SUBMIT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/claims/{id}/submit", Body(body)), "IPD.ClaimSubmit", $"Claim {id} submitted to the TPA", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ClaimEvent(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SUBMIT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/claims/{id}/event", Body(body)), "IPD.ClaimEvent", $"Claim {id}: TPA query / reply / note", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Checklist([FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SUBMIT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync("/insurance/checklist", Body(body)), "IPD.ClaimChecklist", "Claim document checklist", 0);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadDocument(int id, IFormFile? file, [FromForm] int claimId, [FromForm] int? docTypeId, [FromForm] string? title, [FromForm] string? remarks)
    {
        if (!await Can(ClaimsPage, "SUBMIT")) return Fail(PermissionFilter.DeniedMessage);
        string? path;
        try { path = await IpdUploads.SaveAsync(env, file, "ipd/tpa", IpdUploads.Documents); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        if (path is null) return Fail("Choose the file to upload.");
        return await Write(() => api.PostAsync($"/admissions/{id}/tpa-documents", new { PreAuthId = (int?)null, ClaimId = claimId, DocTypeId = docTypeId, Title = title, FilePath = path, Remarks = remarks }),
            "IPD.TpaDocument", $"Claim {claimId}: document uploaded", claimId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Settle(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SETTLE")) return Fail(PermissionFilter.DeniedMessage);
        var (result, row) = await WriteRow(() => api.PostAsync($"/claims/{id}/settle", Body(body)), "IPD.ClaimSettle", $"Claim {id}: settlement entered", id);
        // a write-off asked: tell the approvers of the branch
        if (row.ValueKind == JsonValueKind.Object && row.B("Success") && row.NI("WriteOffId") is int wo)
        {
            try
            {
                var me = User.GetUserId();
                var to = (await approvals.MatrixApproversAsync(User.GetCompanyId(), WriteOffModule, User.GetCurrentBranchId() ?? 0)).Where(u => u != me).ToList();
                if (to.Count > 0)
                    await notifications.NotifyUsersAsync(to, "IPD_APPROVAL", "INFO", "TPA claim write-off to approve",
                        $"{User.Identity?.Name} asked to write off a disallowed amount on claim {row.S("SettlementNo")}.", Url.Action(nameof(Index)), "IPD", wo,
                        $"{WriteOffModule}:{wo}", User.GetCurrentBranchId(), me);
            }
            catch (Exception ex) { logger.LogWarning(ex, "[IPD-TPA] write-off notification failed"); }
        }
        return result;
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelSettlement(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "SETTLE_CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/claim-settlements/{id}/cancel", Body(body)), "IPD.ClaimSettlementCancel", $"Claim settlement {id} cancelled", id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DecideWriteOff(int id, [FromBody] JsonElement body)
    {
        if (!await Can(ClaimsPage, "WRITEOFF_APPROVE")) return Fail(PermissionFilter.DeniedMessage);
        var me = User.GetUserId();
        var approvers = await approvals.MatrixApproversAsync(User.GetCompanyId(), WriteOffModule, User.GetCurrentBranchId() ?? 0);
        if (approvers.Count > 0 && !approvers.Contains(me) && !User.IsSuperAdmin())
            return Fail("Only the approvers named in the Approval Matrix for IPD TPA Claim Write-off can decide it.");
        var approve = body.ValueKind == JsonValueKind.Object && body.TryGetProperty("approve", out var a) && a.ValueKind == JsonValueKind.True;
        return await Write(() => api.PostAsync($"/claim-writeoffs/{id}/decide", Body(body)), "IPD.ClaimWriteOff", $"Claim write-off {id} {(approve ? "approved" : "rejected")}", id);
    }

    // ── IPD > TPA Receivable & Ageing ────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult Ageing()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> AgeingLookups() => Read(LookupsData);

    [HttpGet]
    public Task<IActionResult> AgeingData(DateTime? asOf, int? insuranceTpaId, string? basis) => Read(async () =>
    {
        var sets = await api.SetsAsync("/tpa/ageing?" + Q(("asOf", asOf), ("insuranceTpaId", insuranceTpaId is > 0 ? insuranceTpaId : null), ("basis", basis)));
        return new { tpas = sets.ElementAtOrDefault(0).Items(), claims = sets.ElementAtOrDefault(1).Items(), claimsUrl = Url.Action(nameof(Index)) };
    });

    [HttpGet]
    public Task<IActionResult> StatementData(int insuranceTpaId, DateTime? fromDate, DateTime? toDate) => Read(async () =>
    {
        var to = (toDate ?? DateTime.Today).Date;
        var from = (fromDate ?? to.AddMonths(-3)).Date;
        if (from > to) throw new InvalidOperationException("The from date is after the to date.");
        var sets = await api.SetsAsync($"/tpa/{insuranceTpaId}/statement?" + Q(("fromDate", from), ("toDate", to)));
        return new { head = sets.First(0), rows = sets.ElementAtOrDefault(1).Items() };
    });

    // ── Master > IPD Master > TPA Document Checklist ─────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> DocTypes()
    {
        ViewData["CanEDIT"] = await Can(DocTypesPage, "EDIT");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> DocTypesData() => Read(async () => (await api.GetAsync("/tpa-doctypes")).Items());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveDocType([FromBody] JsonElement body)
    {
        if (!await Can(DocTypesPage, "EDIT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync("/tpa-doctypes", Body(body)), "IPD.TpaDocTypeSave", "TPA document checklist master saved", 0);
    }
}
