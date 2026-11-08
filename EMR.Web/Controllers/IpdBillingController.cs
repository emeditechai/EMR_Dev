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
/// IPD billing (Phase 5, SQLScripts/2434): charges of the IPD Patient workspace (services, procedures, doctor visits),
/// package, bill preview, final bill, bill cancel, the bill print and IPD > IPD Bills.
/// Rights are the controls of IPD.PATIENT (CHARGE, CHARGE_CANCEL, RATE_EDIT, DISCOUNT, PACKAGE, FINAL_BILL, BILL_BACKDATE,
/// BILL_CANCEL); the stored procedures check the rate / discount rights again. Web -> EMR.Api api/ipd -> stored procedures.
/// </summary>
[Authorize]
public class IpdBillingController(IpdApiClient api, IActionPermissionGuard permissionGuard, IPrintTemplateRuntime printRuntime,
    IAuditLogService auditLogService, ILogger<IpdBillingController> logger) : Controller
{
    public const string BillsPage = "IPD.BILLS";
    private const string PatientPage = IpdAdmissionController.PatientPage;

    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string control) => permissionGuard.AllowsAsync(HttpContext, PatientPage, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, int? refId)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD Billing", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    // ── workspace reads ───────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> ChargeLookups(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/charge-lookups");
        return new { services = s.ElementAtOrDefault(0), procedures = s.ElementAtOrDefault(1), doctors = s.ElementAtOrDefault(2), packages = s.ElementAtOrDefault(3), packageItems = s.ElementAtOrDefault(4) };
    });

    [HttpGet]
    public Task<IActionResult> Charges(int id, string? head, bool includeCancelled = false) => Read(async () =>
        await api.GetAsync($"/admissions/{id}/charges" + IpdApiClient.Q(("head", head), ("includeCancelled", includeCancelled))));

    [HttpGet]
    public Task<IActionResult> Preview(int id, DateTime? upTo, string? discountType, decimal discountValue = 0) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/bill-preview" + IpdApiClient.Q(("upTo", upTo?.ToString("yyyy-MM-ddTHH:mm:ss")), ("discountType", discountType), ("discountValue", discountValue)));
        return new { totals = s.ElementAtOrDefault(0), heads = s.ElementAtOrDefault(1) };
    });

    // ── writes ────────────────────────────────────────────────────────────────────────────────────────────────
    public sealed class ChargeLine
    {
        public string Kind { get; set; } = "";
        public int? RefId { get; set; }
        public string? Head { get; set; }
        public string? ItemName { get; set; }
        public decimal Qty { get; set; } = 1;
        public decimal? Rate { get; set; }
        public decimal Discount { get; set; }
        public decimal GstPercent { get; set; }
        public int? DoctorId { get; set; }
        public DateTime? ChargeAt { get; set; }
        public string? Remarks { get; set; }
        public bool ExcludePackage { get; set; }
        public string? VisitType { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> AddCharges(int id, [FromBody] List<ChargeLine> lines)
    {
        if (!await Can("CHARGE")) return Fail(PermissionFilter.DeniedMessage);
        if (lines is not { Count: > 0 }) return Fail("Add at least one charge.");
        var canRate = await Can("RATE_EDIT");
        var canDisc = await Can("DISCOUNT");
        var json = JsonSerializer.Serialize(lines);
        return await Write(() => api.PostAsync($"/admissions/{id}/charges", new { Lines = json, CanEditRate = canRate, CanDiscount = canDisc }),
            "IPD.ChargeAdd", $"Admission {id}: {lines.Count} charge(s) added - " + string.Join(", ", lines.Select(l => l.ItemName ?? l.Kind)), id);
    }

    public sealed class ReasonBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelCharge(long chargeId, [FromBody] ReasonBody b)
    {
        if (!await Can("CHARGE_CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/charges/{chargeId}/cancel", new { b.Reason }), "IPD.ChargeCancel", $"Charge {chargeId} cancelled: {b.Reason}", (int)chargeId);
    }

    public sealed class PackageBody { public int? PackageId { get; set; } public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SetPackage(int id, [FromBody] PackageBody b)
    {
        if (!await Can("PACKAGE")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/admissions/{id}/package", new { b.PackageId, b.Reason }), "IPD.Package", $"Admission {id}: package → {b.PackageId?.ToString() ?? "none"} {b.Reason}", id);
    }

    public sealed class FinaliseBody
    {
        public DateTime? UpTo { get; set; }
        public string? DiscountType { get; set; }
        public decimal DiscountValue { get; set; }
        public string? DiscountReason { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Finalise(int id, [FromBody] FinaliseBody b)
    {
        if (!await Can("FINAL_BILL")) return Fail(PermissionFilter.DeniedMessage);
        var canDisc = await Can("DISCOUNT");
        var canBack = await Can("BILL_BACKDATE");
        return await Write(() => api.PostAsync($"/admissions/{id}/final-bill", new { b.UpTo, b.DiscountType, b.DiscountValue, b.DiscountReason, b.Remarks, CanDiscount = canDisc, CanBackdate = canBack }),
            "IPD.FinalBill", $"Admission {id}: final bill made" + (b.DiscountValue > 0 ? $", discount {b.DiscountValue}{(b.DiscountType == "P" ? "%" : "")} ({b.DiscountReason})" : ""), id);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CancelBill(int billId, [FromBody] ReasonBody b)
    {
        if (!await Can("BILL_CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/bills/{billId}/cancel", new { b.Reason }), "IPD.BillCancel", $"IPD bill {billId} cancelled: {b.Reason}", billId);
    }

    // ── bills list and print ──────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public IActionResult Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ListData(DateTime? fromDate, DateTime? toDate, string? status, string? search) => Read(async () =>
        await api.GetAsync("/bills" + IpdApiClient.Q(("fromDate", fromDate?.ToString("yyyy-MM-dd")), ("toDate", toDate?.ToString("yyyy-MM-dd")), ("status", status), ("search", search))));

    /// <summary>Final bill print: summary (by head) or detailed (every line).</summary>
    [HttpGet]
    public async Task<IActionResult> PrintBill(int id, string? format)
    {
        try
        {
            var s = await api.SetsAsync($"/bills/{id}");
            var bill = s.First(0); var header = s.First(1);
            if (!bill.Has() || !header.Has() || bill.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, bill.I("BranchId"), new PrintDocInfo
                { DocNo = bill.S("BillNo"), DocDate = bill.Dt("BillAt"), CopyLabel = bill.S("Status") == "CANCELLED" ? "Cancelled" : "Original", PrintedBy = this.PrintedBy() });
            return View(new IpdPrintView
            {
                Title = "IPD Final Bill", DocNo = bill.S("BillNo"), Header = header, Doc = bill, Rows = s.ElementAtOrDefault(2).Items(),
                Rows2 = s.ElementAtOrDefault(3).Items(), Totals = s.ElementAtOrDefault(4), Format = format == "detail" ? "detail" : "summary", PrintedBy = this.PrintedBy()
            });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "IPD Bill"; return View("ApiDown"); }
    }
}
