using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Settings > Payment QR Configuration (SQLScripts/2452): the UPI QR of each branch (UPI ID, payee, amount on the QR or
/// not, invoice no in the note, caption), with a live preview. Used by the B2B tax invoice when Hospital Settings (OPD tab)
/// "Show QR on B2B Invoice" is Yes. Page SETTINGS.PAYMENTQR: VIEW, EDIT, STATUS. Web -> EMR.Api api/payment-qr -> procedures.
/// </summary>
[Authorize]
public class PaymentQrConfigController(PaymentQrApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService,
    ILogger<PaymentQrConfigController> logger) : Controller
{
    public const string Page = "SETTINGS.PAYMENTQR";
    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        foreach (var c in new[] { "EDIT", "STATUS" }) ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, Page, c);
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> ListData()
    {
        try { return Json(new { success = true, data = await api.GetAsync() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Payment QR API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    public sealed class QrBody
    {
        public int BranchId { get; set; }
        public string? UpiId { get; set; }
        public string? PayeeName { get; set; }
        public string? MerchantCode { get; set; }
        public string AmountMode { get; set; } = "DUE";
        public bool IncludeReference { get; set; } = true;
        public string? Caption { get; set; }
        public bool IsActive { get; set; } = true;
        public decimal? SampleAmount { get; set; }
    }

    /// <summary>The QR as it will print, for a sample amount and invoice no (nothing saved).</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public IActionResult Preview([FromBody] QrBody b)
    {
        if (string.IsNullOrWhiteSpace(b.UpiId) || string.IsNullOrWhiteSpace(b.PayeeName)) return Fail("Enter the UPI ID and payee name to preview.");
        var cfg = new UpiQrConfig(b.UpiId.Trim().ToLowerInvariant(), b.PayeeName.Trim(), b.MerchantCode, b.AmountMode == "OPEN" ? "OPEN" : "DUE", b.IncludeReference, b.Caption, true);
        var link = UpiQr.Link(cfg, b.SampleAmount ?? 1250m, "B2B/HO/26-27/0001");
        return Json(new { success = true, data = new { link, image = UpiQr.PngDataUri(link, 6) } });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] QrBody b)
    {
        try
        {
            // turning a branch QR on / off on this form needs the Status right as well
            var row = await api.PostAsync("", new { b.BranchId, b.UpiId, b.PayeeName, b.MerchantCode, b.AmountMode, b.IncludeReference, b.Caption,
                IsActive = await permissionGuard.AllowsAsync(HttpContext, Page, "STATUS") ? b.IsActive : true });
            if (!row.B("Success")) return Fail(row.S("Error") ?? "Not saved.");
            await auditLogService.LogActivityAsync(eventType: "Settings", actionName: "PaymentQr.Save",
                description: $"Payment QR of branch {b.BranchId} set: {b.UpiId} ({b.PayeeName}), {b.AmountMode}", userId: User.GetUserId(),
                branchId: b.BranchId, moduleCode: "SETTINGS", referenceId: row.I("ConfigId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Payment QR API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved."); }
    }

    public sealed class StatusBody { public int BranchId { get; set; } public bool IsActive { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SetStatus([FromBody] StatusBody b)
    {
        try
        {
            var row = await api.PostAsync($"/branch/{b.BranchId}/status", new { b.IsActive });
            if (!row.B("Success")) return Fail(row.S("Error") ?? "Not changed.");
            await auditLogService.LogActivityAsync(eventType: "Settings", actionName: "PaymentQr.Status", description: $"Payment QR of branch {b.BranchId} turned {(b.IsActive ? "on" : "off")}",
                userId: User.GetUserId(), branchId: b.BranchId, moduleCode: "SETTINGS", referenceId: row.I("ConfigId"));
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException) { return Fail("The EMR API is not reachable. Nothing was changed."); }
    }
}
