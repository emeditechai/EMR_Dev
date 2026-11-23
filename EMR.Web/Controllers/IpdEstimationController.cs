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
/// IPD > Current Billing Estimation (real-time bill of an admitted patient, the due list of all admitted patients and
/// their prints) and IPD > Pre-admission Estimate (SQLScripts/2422-2424). Read only: the bill itself never changes here.
/// </summary>
[Authorize]
public class IpdEstimationController(
    IpdApiClient api,
    IPrintTemplateRuntime printRuntime,
    IAuditLogService auditLogService,
    ILogger<IpdEstimationController> logger) : Controller
{
    public const string EstimationPage = "IPD.ESTIMATION";
    public const string PreEstimatePage = "IPD.PREESTIMATE";

    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> ApiJson(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private static object Named(List<JsonElement> sets, params string[] names) =>
        names.Select((n, i) => (n, i)).ToDictionary(x => x.n, x => x.i < sets.Count ? (object)sets[x.i] : Array.Empty<object>());

    private static string LiveUrl(int id, DateTime? asOf, DateTime? projectTo) =>
        $"/estimate/{id}" + IpdApiClient.Q(("asOf", asOf?.ToString("yyyy-MM-ddTHH:mm:ss")), ("projectTo", projectTo?.ToString("yyyy-MM-ddTHH:mm:ss")));

    // ── due list ─────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult Index() => User.GetCurrentBranchId() is null ? RedirectToAction("SelectBranch", "Account") : View();

    [HttpGet]
    public Task<IActionResult> DueListData(int? wardId, string? payerType, string? search, bool onlyAlerts = false) =>
        ApiJson(async () => await api.GetAsync("/estimate/due-list" + IpdApiClient.Q(("wardId", wardId), ("payerType", payerType), ("search", search), ("onlyAlerts", onlyAlerts))));

    // ── one patient, live ────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Patient(int id)
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        try
        {
            var sets = await api.SetsAsync(LiveUrl(id, null, null));
            var header = sets.First(0);
            if (!header.Has() || header.I("BranchId") != User.GetCurrentBranchId()) return NotFound();
            return View(header);
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Current Billing Estimation"; return View("ApiDown"); }
        catch (InvalidOperationException ex) { TempData["Error"] = ex.Message; return RedirectToAction(nameof(Index)); }
    }

    [HttpGet]
    public Task<IActionResult> LiveData(int id, DateTime? projectTo) =>
        ApiJson(async () => Named(await api.SetsAsync(LiveUrl(id, null, projectTo)), "header", "heads", "totals", "ordered"));

    [HttpGet]
    public Task<IActionResult> LinesData(int id, string? head, string? status, DateTime? fromDate, DateTime? toDate, string? search) =>
        ApiJson(async () => await api.GetAsync($"/estimate/{id}/lines" + IpdApiClient.Q(("head", head), ("status", status), ("fromDate", fromDate),
            ("toDate", toDate), ("search", search))));

    /// <summary>Prints: summary | head (detailed by head) | date (detailed by date) | projection (till discharge) | deposit (request letter).</summary>
    [HttpGet]
    public async Task<IActionResult> Print(int id, string? format, DateTime? projectTo)
    {
        format = format?.ToLowerInvariant() switch { "head" => "head", "date" => "date", "projection" => "projection", "deposit" => "deposit", _ => "summary" };
        try
        {
            var asOf = DateTime.Now;
            var sets = await api.SetsAsync(LiveUrl(id, asOf, projectTo));
            var header = sets.First(0);
            if (!header.Has() || header.I("BranchId") != User.GetCurrentBranchId()) return NotFound();
            var lines = format is "head" or "date" ? (await api.GetAsync($"/estimate/{id}/lines" + IpdApiClient.Q(("asOf", asOf.ToString("yyyy-MM-ddTHH:mm:ss"))))).Items() : [];
            var branchId = User.GetCurrentBranchId() ?? 0;
            var printedBy = this.PrintedBy();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, branchId, new PrintDocInfo
                { DocNo = header.S("IpNo"), DocDate = asOf.ToString("dd-MMM-yyyy hh:mm tt"), CopyLabel = "Provisional", PrintedBy = printedBy });
            await auditLogService.LogActivityAsync(eventType: "IPD Billing", actionName: "IPD.EstimatePrint", description: $"Current estimate printed ({format}) for {header.S("IpNo")}.",
                userId: User.GetUserId(), branchId: branchId, moduleCode: "IPD", referenceNo: header.S("IpNo"), referenceId: id);
            return View(new IpdPrintView
            {
                Title = format switch { "deposit" => "Deposit Request", "projection" => "Estimate till Discharge", _ => "Provisional Bill Estimate" },
                DocNo = header.S("IpNo"), Header = header, Rows = sets.ElementAtOrDefault(1).Items(), Totals = sets.First(2), Rows2 = lines,
                Format = format, PrintedBy = printedBy
            });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Estimate Print"; return View("ApiDown"); }
    }

    // ── pre-admission estimate ───────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult PreAdmission() => User.GetCurrentBranchId() is null ? RedirectToAction("SelectBranch", "Account") : View();

    [HttpGet]
    public Task<IActionResult> PreAdmissionData(string? status, DateTime? fromDate, DateTime? toDate, string? search, int? patientId) =>
        ApiJson(async () => await api.GetAsync("/pre-estimates" + IpdApiClient.Q(("status", status), ("fromDate", fromDate), ("toDate", toDate),
            ("search", search), ("patientId", patientId))));

    [HttpGet]
    public async Task<IActionResult> PreAdmissionForm(int? id)
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        ViewBag.EstimateId = id;
        if (id is > 0)
        {
            try
            {
                var sets = await api.SetsAsync($"/pre-estimates/{id}");
                var head = sets.First(0);
                if (!head.Has() || head.I("BranchId") != User.GetCurrentBranchId()) return NotFound();
                ViewBag.EstimateJson = JsonSerializer.Serialize(new { header = head, lines = sets.ElementAtOrDefault(1) });
            }
            catch (HttpRequestException) { ViewData["PageName"] = "Pre-admission Estimate"; return View("ApiDown"); }
        }
        return View();
    }

    [HttpGet]
    public Task<IActionResult> PreAdmissionLookups() => ApiJson(async () =>
    {
        var s = await api.SetsAsync("/lookups");
        return Named(s, "doctors", "referralDoctors", "departments", "tariffCategories", "insurances", "corporates", "schemes", "packages", "consents",
            "paymentModes", "settings", "bedCategories");
    });

    [HttpGet]
    public Task<IActionResult> PreAdmissionCalc(int tariffCategoryId, int? bedCategoryId, int wardDays, int? icuBedCategoryId, int icuDays, int? packageId) =>
        ApiJson(async () => Named(await api.SetsAsync("/pre-estimates/calc" + IpdApiClient.Q(("tariffCategoryId", tariffCategoryId), ("bedCategoryId", bedCategoryId),
            ("wardDays", wardDays), ("icuBedCategoryId", icuBedCategoryId), ("icuDays", icuDays), ("packageId", packageId))), "lines", "missing"));

    public sealed class PreEstimateBody
    {
        public int? EstimateId { get; set; }
        public int? PatientId { get; set; }
        public string? PatientName { get; set; }
        public string? Phone { get; set; }
        public string? AgeText { get; set; }
        public string? Gender { get; set; }
        public string PayerType { get; set; } = "CASH";
        public int TariffCategoryId { get; set; }
        public int? BedCategoryId { get; set; }
        public int WardDays { get; set; }
        public int? IcuBedCategoryId { get; set; }
        public int IcuDays { get; set; }
        public int? PackageId { get; set; }
        public int? DoctorId { get; set; }
        public string? ProcedureNote { get; set; }
        public string? Remarks { get; set; }
        public string? Lines { get; set; }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePreAdmission([FromBody] PreEstimateBody b)
    {
        try
        {
            var row = await api.PostAsync("/pre-estimates", new
            {
                b.EstimateId, b.PatientId, b.PatientName, b.Phone, b.AgeText, b.Gender, b.PayerType, b.TariffCategoryId, b.BedCategoryId, b.WardDays,
                b.IcuBedCategoryId, b.IcuDays, b.PackageId, b.DoctorId, b.ProcedureNote, b.Remarks, Lines = b.Lines ?? "[]"
            });
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The estimate could not be saved.");
            await auditLogService.LogActivityAsync(eventType: "IPD Billing", actionName: "IPD.PreEstimate", description: $"Pre-admission estimate {row.S("EstimateNo")} saved for {b.PatientName}.",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceNo: row.S("EstimateNo"), referenceId: row.I("EstimateId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException) { return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelPreAdmission(int id)
    {
        try
        {
            var row = await api.PostAsync($"/pre-estimates/{id}/cancel", new { });
            return row.B("Success") ? Json(new { success = true }) : Fail(row.S("Error"));
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException) { return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> PrintPreAdmission(int id)
    {
        try
        {
            var sets = await api.SetsAsync($"/pre-estimates/{id}");
            var head = sets.First(0);
            if (!head.Has() || head.I("BranchId") != User.GetCurrentBranchId()) return NotFound();
            var branchId = User.GetCurrentBranchId() ?? 0;
            var printedBy = this.PrintedBy();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, branchId, new PrintDocInfo
                { DocNo = head.S("EstimateNo"), DocDate = head.Dt("EstimateDate"), CopyLabel = "Estimate", PrintedBy = printedBy });
            return View(new IpdPrintView { Title = "Cost Estimate (Pre-admission)", DocNo = head.S("EstimateNo"), Doc = head, Rows = sets.ElementAtOrDefault(1).Items(), PrintedBy = printedBy });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Pre-admission Estimate"; return View("ApiDown"); }
    }
}
