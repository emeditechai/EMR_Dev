using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// LAB > Marketing Executive Sales Target (LAB.MARKETINGTARGETS: VIEW, EDIT) and LAB > Doctor Visit Log
/// (LAB.MARKETINGVISITS: VIEW, ADD, DELETE) - SQLScripts/2446. Targets are per branch (the signed-in branch) and financial
/// year, in Monthly / Quarterly / Half-yearly / Yearly buckets of sales (Rs.) and doctor visits. Reports > LAB >
/// Marketing Executive Business takes its targets from here. Web -> EMR.Api api/marketing-executives -> procedures.
/// </summary>
[Authorize]
public class MarketingTargetsController(MarketingExecutiveApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, ILogger<MarketingTargetsController> logger) : Controller
{
    public const string TargetPage = "LAB.MARKETINGTARGETS", VisitPage = "LAB.MARKETINGVISITS";
    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private int Branch => User.GetCurrentBranchId() ?? 0;

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        if (Branch <= 0) return Fail("Your branch could not be found - sign in again.");
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Marketing target API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, string idField)
    {
        if (Branch <= 0) return Fail("Your branch could not be found - sign in again.");
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "LAB", actionName: action, description: description, userId: User.GetUserId(),
                branchId: Branch, moduleCode: "LAB", referenceId: row.I(idField));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Marketing target API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    // ── Sales Target ────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewData["CanEDIT"] = await permissionGuard.AllowsAsync(HttpContext, TargetPage, "EDIT");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ListData(DateTime? fyStart) => Read(async () =>
    {
        var years = await api.GetAsync("/targets/years");
        var fy = fyStart ?? years.EnumerateArray().Where(y => y.B("IsCurrent")).Select(y => y.GetProperty("FyStart").GetDateTime()).FirstOrDefault();
        var rows = await api.GetAsync("/targets" + IpdApiClient.Q(("branchId", Branch.ToString()), ("fyStart", fy.ToString("yyyy-MM-dd"))));
        return new { years, fyStart = fy.ToString("yyyy-MM-dd"), rows };
    });

    [HttpGet]
    public Task<IActionResult> Get(int executiveId, DateTime fyStart, string? frequency) =>
        Read(async () => await api.GetAsync($"/targets/{executiveId}" + IpdApiClient.Q(("branchId", Branch.ToString()), ("fyStart", fyStart.ToString("yyyy-MM-dd")), ("frequency", frequency))));

    public sealed class TargetBody
    {
        public int ExecutiveId { get; set; }
        public DateTime FyStart { get; set; }
        public string? Frequency { get; set; }
        public List<BucketBody> Buckets { get; set; } = new();
        public string? Remarks { get; set; }
    }
    public sealed class BucketBody { public int BucketNo { get; set; } public decimal SalesTarget { get; set; } public decimal VisitTarget { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> Save([FromBody] TargetBody b)
    {
        var buckets = JsonSerializer.Serialize(b.Buckets.Select(x => new { bucketNo = x.BucketNo, salesTarget = x.SalesTarget, visitTarget = x.VisitTarget }));
        return Write(() => api.PostAsync("/targets", new { BranchId = Branch, b.ExecutiveId, b.FyStart, b.Frequency, Buckets = buckets, b.Remarks }),
            "MarketingTarget.Save", $"Marketing target set: executive {b.ExecutiveId}, FY from {b.FyStart:yyyy-MM-dd}, {b.Frequency}, sales {b.Buckets.Sum(x => x.SalesTarget):0.00}, visits {b.Buckets.Sum(x => x.VisitTarget):0}", "TargetId");
    }

    // ── Doctor Visit Log ────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Visits()
    {
        foreach (var c in new[] { "ADD", "DELETE" }) ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, VisitPage, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> VisitData(DateTime fromDate, DateTime toDate, int? executiveId, string? search) =>
        Read(async () => await api.GetAsync("/visits" + IpdApiClient.Q(("branchId", Branch.ToString()), ("fromDate", fromDate.ToString("yyyy-MM-dd")),
            ("toDate", toDate.ToString("yyyy-MM-dd")), ("executiveId", executiveId?.ToString()), ("search", search))));

    [HttpGet]
    public Task<IActionResult> VisitDoctors(int? executiveId) =>
        Read(async () => await api.GetAsync("/visits/doctors" + IpdApiClient.Q(("executiveId", executiveId?.ToString()))));

    public sealed class VisitBody
    {
        public int? ExecutiveId { get; set; }
        public int DoctorId { get; set; }
        public DateTime? VisitDate { get; set; }
        public string? Purpose { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> VisitSave([FromBody] VisitBody b) =>
        Write(() => api.PostAsync("/visits", new { BranchId = Branch, b.ExecutiveId, b.DoctorId, b.VisitDate, b.Purpose, b.Remarks }),
            "MarketingVisit.Add", $"Doctor visit logged: executive {b.ExecutiveId}, doctor {b.DoctorId}, {b.VisitDate:dd-MMM-yyyy HH:mm}, {b.Purpose}", "VisitId");

    [HttpPost, ValidateAntiForgeryToken]
    public Task<IActionResult> VisitDelete(int id) =>
        Write(() => api.PostAsync($"/visits/{id}/delete", new { BranchId = Branch }), "MarketingVisit.Delete", $"Doctor visit {id} deleted", "VisitId");
}
