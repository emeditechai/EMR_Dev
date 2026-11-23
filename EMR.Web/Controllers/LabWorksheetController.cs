using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// LAB > Work Sheet (LAB.WORKSHEET, SQLScripts/2477): the numeric tests of one day's bills (order / booking / sample
/// collection date; B2C / B2B / all), bill-wise, profiles with their tests under the profile name, the value already
/// entered or a blank box - printed on A4 (or exported to PDF) for the bench hard copy. Controls: VIEW, PRINT.
/// Web -> EMR.Api api/lab-worksheet -> usp_Api_LabWorksheet_List.
/// </summary>
[Authorize]
public class LabWorksheetController(LabWorksheetApiClient api, IActionPermissionGuard permissionGuard, IPrintTemplateRuntime printTemplates,
    ILabReportPdfService reports, IAuditLogService auditLogService, ILogger<LabWorksheetController> logger) : Controller
{
    public const string Page = "LAB.WORKSHEET";
    private int Branch => HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 0;
    private int Company => int.TryParse(User.FindFirst("CompanyId")?.Value, out var c) && c > 0 ? c : 1;

    private static (string DateType, string Channel, string Values) Clean(string? dateType, string? channel, string? values) =>
        (dateType?.ToUpperInvariant() is "BOOKING" or "COLLECTION" ? dateType.ToUpperInvariant() : "ORDER",
         channel?.ToUpperInvariant() is "B2C" or "B2B" ? channel.ToUpperInvariant() : "ALL",
         values?.ToUpperInvariant() is "WITH" or "WITHOUT" ? values.ToUpperInvariant() : "ALL");

    private async Task<LabWorksheetDoc> LoadAsync(string? dateType, DateTime? date, string? channel, string? values)
    {
        var (dt, ch, vf) = Clean(dateType, channel, values);
        var day = (date ?? DateTime.Today).Date;
        return LabWorksheetDoc.From(await api.ListAsync(Branch, dt, day, ch, vf), day, dt, ch, vf);
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewData["CanPrint"] = await permissionGuard.AllowsAsync(HttpContext, Page, "PRINT");
        return View("~/Views/LabWorksheet/Index.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Data(string? dateType, DateTime? date, string? channel, string? values)
    {
        try
        {
            var d = await LoadAsync(dateType, date, channel, values);
            return Json(new
            {
                success = true,
                data = new
                {
                    subtitle = d.Subtitle, tests = d.TestCount, filled = d.FilledCount,
                    bills = d.Bills.Select(b => new
                    {
                        b.LabOrderId, b.BillNo, b.TokenNo, b.BillDate, b.Channel, b.PatientName, b.PatientCode, b.AgeSex, b.CollectedAt,
                        groups = b.Groups.Select(g => new { g.ProfileName, tests = g.Tests.Select(t => new { t.TestName, t.Unit, t.CollectedAt, t.Value, t.Flag }) })
                    })
                }
            });
        }
        catch (InvalidOperationException ex) { return Json(new { success = false, error = ex.Message }); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Work sheet: API unreachable"); return Json(new { success = false, error = "The EMR API is not reachable. Try again in a moment." }); }
    }

    /// <summary>Header / footer: the branch's Lab Report print template (Utility > Print Templates), else the hospital details.</summary>
    private async Task DecorateAsync(LabWorksheetDoc d)
    {
        d.PrintedBy = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name ?? "";
        d.PrintedAt = DateTime.Now;
        var s = await printTemplates.SettingsAsync(Branch);
        d.HospitalName = s?.HospitalName;
        d.HospitalAddress = s?.Address;
        d.HospitalContact = string.Join(" · ", new[] { s?.ContactNumber1, s?.EmailAddress }.Where(x => !string.IsNullOrWhiteSpace(x)));
        d.LogoUrl = s?.LogoPath;
        try
        {
            var (layout, values) = await printTemplates.ForReportAsync(User, Company, Branch, new PrintDocInfo
            {
                DocNo = "Work Sheet", DocDate = d.Date.ToString("dd-MMM-yyyy"), CopyLabel = d.Subtitle,
                PrintedAt = d.PrintedAt.ToString("dd-MMM-yyyy hh:mm tt"), PrintedBy = d.PrintedBy
            }, null);
            d.Template = layout;
            d.Values = values;
            if (values.GetValueOrDefault("__logo") is { Length: > 0 } logo) d.LogoUrl = logo;
            if (layout is not null)
                foreach (var path in new[] { layout.Header, layout.Footer }.SelectMany(b => b.Rows).SelectMany(r => r.Cols).SelectMany(c => c.Blocks)
                             .Where(b => b.Type == "image" && !string.IsNullOrWhiteSpace(b.ImageUrl)).Select(b => b.ImageUrl!).Distinct())
                    if (reports.LoadLogo(path) is { } bytes) d.Images[path] = bytes;
        }
        catch (Exception ex) { logger.LogWarning(ex, "Work sheet: print template not applied, the hospital details are used"); }
        d.Logo = reports.LoadLogo(d.LogoUrl);
    }

    private Task AuditAsync(string action, LabWorksheetDoc d) => auditLogService.LogActivityAsync(eventType: "LAB Work Sheet", actionName: action,
        description: $"Work sheet {d.Subtitle}", userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "LAB", referenceId: 0);

    [HttpGet]
    public async Task<IActionResult> Print(string? dateType, DateTime? date, string? channel, string? values)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, "PRINT")) return Forbid();
        try
        {
            var d = await LoadAsync(dateType, date, channel, values);
            await DecorateAsync(d);
            await AuditAsync("LAB.WorksheetPrint", d);
            ViewData["PdfUrl"] = Url.ActionEncrypted(nameof(Pdf), new { dateType = d.DateType, date = d.Date.ToString("yyyy-MM-dd"), channel = d.Channel, values = d.ValueFilter });
            return View("~/Views/LabWorksheet/Print.cshtml", d);
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { return Content("The work sheet could not be loaded: " + ex.Message); }
    }

    [HttpGet]
    public async Task<IActionResult> Pdf(string? dateType, DateTime? date, string? channel, string? values)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, "PRINT")) return Forbid();
        try
        {
            var d = await LoadAsync(dateType, date, channel, values);
            await DecorateAsync(d);
            await AuditAsync("LAB.WorksheetPdf", d);
            return File(LabWorksheetPdf.Build(d), "application/pdf", $"WorkSheet_{d.DateType}_{d.Channel}_{d.Date:yyyyMMdd}.pdf");
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException) { return Content("The work sheet could not be loaded: " + ex.Message); }
    }
}
