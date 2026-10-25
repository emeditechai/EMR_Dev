using Dapper;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Print Templates (SQLScripts/2324), page UTILITY.PRINTTEMPLATES: VIEW (list, designer, preview), EDIT (design
/// drafts), PUBLISH (make live, assign to branches). A template is the header and footer of printed bills (LAB and OPD)
/// or of lab reports (PDF: print, email, WhatsApp); the body of the documents does not change. A branch without a
/// template prints the Classic header and footer, exactly as before.
/// </summary>
[Authorize]
public class PrintTemplatesController(
    IPrintTemplateApiClient api,
    IPrintTemplateRuntime runtime,
    ILabReportPdfService reportPdf,
    IDbConnectionFactory db,
    IWebHostEnvironment env,
    IAuditLogService audit,
    ILogger<PrintTemplatesController> logger) : Controller
{
    public const string PageCode = PrintTemplateRuntime.PageCode;   // UTILITY.PRINTTEMPLATES
    private int CompanyId => User.GetCompanyId();
    private int UserId => User.GetUserId();
    private int CurrentBranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 0;

    /// <summary>Templates are designed, published and assigned by the head office (a Super Admin signed in without a
    /// branch too). Other branches see the templates and preview them, but change nothing.</summary>
    private bool CanManage => User.IsHOBranch() || (User.IsSuperAdmin() && User.GetCurrentBranchId() is null);
    private const string HoOnly = "Only the head office can create, change, publish or assign print templates.";
    private IActionResult HoOnlyRedirect() { TempData["ErrorMessage"] = HoOnly; return RedirectToAction(nameof(Index)); }
    private IActionResult HoOnlyJson() => Json(new { success = false, error = HoOnly });

    private static string KindTitle(string kind) => kind == "REPORT" ? "Lab Report" : "Bill";

    private IActionResult Down() { ViewData["PageName"] = "Print Templates"; return View("ApiDown"); }

    // ── List + branch assignment ─────────────────────────────────────────────────────────────────────────

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index()
    {
        try
        {
            ViewBag.Assignments = await api.AssignmentsAsync(CompanyId);
            ViewBag.CanManage = CanManage;
            return View(await api.ListAsync(CompanyId));
        }
        catch (HttpRequestException) { return Down(); }
    }

    /// <summary>A new template from a ready layout (standard / centred / blank) - changed afterwards in the designer.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Create(string kind, string name, string start)
    {
        if (!CanManage) return HoOnlyRedirect();
        kind = kind == "REPORT" ? "REPORT" : "BILL";
        var layout = start switch { "centred" => PrintLayoutStarters.Centred(kind), "blank" => PrintLayoutStarters.Blank(), _ => PrintLayoutStarters.Standard(kind) };
        var (id, err) = await api.SaveAsync(CompanyId, 0, kind, (name ?? "").Trim(), layout.ToJson(), UserId);
        if (err is not null) { TempData["ErrorMessage"] = err; return RedirectToAction(nameof(Index)); }
        await audit.LogAsync("UTILITY", "PrintTemplates.Create", $"{KindTitle(kind)} print template \"{name}\" created ({start}).");
        return RedirectToAction(nameof(Designer), new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Copy(int id)
    {
        if (!CanManage) return HoOnlyRedirect();
        var t = await api.GetAsync(CompanyId, id);
        if (t is null) return NotFound();
        var name = t.Name.Length > 90 ? t.Name[..90] : t.Name;
        string? err = "start";
        int? newId = null;
        for (var n = 1; err is not null && n <= 20; n++)
            (newId, err) = await api.SaveAsync(CompanyId, 0, t.Kind, $"{name} (copy{(n == 1 ? "" : " " + n)})", t.DraftJson, UserId);
        if (err is not null) { TempData["ErrorMessage"] = err; return RedirectToAction(nameof(Index)); }
        await audit.LogAsync("UTILITY", "PrintTemplates.Copy", $"Print template \"{t.Name}\" copied.");
        return RedirectToAction(nameof(Designer), new { id = newId });
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Delete)]
    public async Task<IActionResult> Delete(int id)
    {
        if (!CanManage) return HoOnlyRedirect();
        var err = await api.DeleteAsync(CompanyId, id, UserId);
        if (err is null) await audit.LogAsync("UTILITY", "PrintTemplates.Delete", $"Print template #{id} removed.");
        TempData[err is null ? "SuccessMessage" : "ErrorMessage"] = err ?? "Template removed.";
        return RedirectToAction(nameof(Index));
    }

    /// <summary>The template a branch prints its bills or reports with (none = Classic). Takes effect at once.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, "ASSIGN")]
    public async Task<IActionResult> Assign(int branchId, string kind, int? templateId)
    {
        if (!CanManage) return HoOnlyJson();
        kind = kind == "REPORT" ? "REPORT" : "BILL";
        var err = await api.AssignAsync(CompanyId, branchId, kind, templateId is > 0 ? templateId : null, UserId);
        if (err is null)
        {
            runtime.Invalidate();
            await audit.LogAsync("UTILITY", "PrintTemplates.Assign",
                $"Branch #{branchId} prints {KindTitle(kind).ToLowerInvariant()}s with {(templateId is > 0 ? $"template #{templateId}" : "the Classic header and footer")}.");
        }
        return Json(new { success = err is null, error = err });
    }

    // ── Designer ─────────────────────────────────────────────────────────────────────────────────────────

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Designer(int id)
    {
        try
        {
            var t = await api.GetAsync(CompanyId, id);
            if (t is null) return NotFound();
            ViewBag.Branches = (await api.AssignmentsAsync(CompanyId)).Select(b => new { b.BranchId, b.BranchName }).ToList();
            ViewBag.PreviewBranchId = CurrentBranchId;
            ViewBag.CanManage = CanManage;
            return View(t);
        }
        catch (HttpRequestException) { return Down(); }
    }

    public class RenderRequest
    {
        public string LayoutJson { get; set; } = "{}";
        public int BranchId { get; set; }
        public string Kind { get; set; } = "BILL";
        public string? Selected { get; set; }
    }

    /// <summary>The designer canvas: header and footer drawn by the same page part the bills print with, filled with the
    /// chosen branch's real details (sample values where the branch has none and for the document fields).</summary>
    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Render([FromForm] RenderRequest r)
    {
        var layout = PrintLayout.Parse(r.LayoutJson) ?? PrintLayoutStarters.Blank();
        var values = await runtime.ValuesAsync(r.BranchId > 0 ? r.BranchId : CurrentBranchId, new PrintDocInfo
        {
            DocNo = r.Kind == "REPORT" ? "LAB/HO2627000296" : "LAB/HO2627000296",
            DocDate = DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt"),
            TokenNo = "LAB-HO-0001",
            CopyLabel = "Original",
            ProcessingLab = null,
            PrintedBy = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name,
            CreatedBy = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name
        });
        values["processingLab"] = values.GetValueOrDefault("hospitalName") + (string.IsNullOrWhiteSpace(values.GetValueOrDefault("address")) ? "" : ", " + values["address"]);
        ViewBag.Selected = r.Selected;
        ViewBag.Values = values;
        return PartialView("_DesignerCanvas", layout);
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Save(int id, string name, string kind, string layoutJson)
    {
        if (!CanManage) return HoOnlyJson();
        var layout = PrintLayout.Parse(layoutJson);
        if (layout is null) return Json(new { success = false, error = "The layout could not be read." });
        var (newId, err) = await api.SaveAsync(CompanyId, id, kind == "REPORT" ? "REPORT" : "BILL", (name ?? "").Trim(), layout.ToJson(), UserId);
        return Json(new { success = err is null, error = err, templateId = newId });
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, "PUBLISH")]
    public async Task<IActionResult> Publish(int id, string name, string kind, string layoutJson)
    {
        if (!CanManage) return HoOnlyJson();
        var layout = PrintLayout.Parse(layoutJson);
        if (layout is null) return Json(new { success = false, error = "The layout could not be read." });
        var (_, saveErr) = await api.SaveAsync(CompanyId, id, kind == "REPORT" ? "REPORT" : "BILL", (name ?? "").Trim(), layout.ToJson(), UserId);
        if (saveErr is not null) return Json(new { success = false, error = saveErr });
        var (version, err) = await api.PublishAsync(CompanyId, id, UserId);
        if (err is null)
        {
            runtime.Invalidate();
            await audit.LogAsync("UTILITY", "PrintTemplates.Publish", $"Print template \"{name}\" published as version {version}.");
        }
        return Json(new { success = err is null, error = err, version });
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Restore(int id, int versionNo)
    {
        if (!CanManage) { TempData["ErrorMessage"] = HoOnly; return RedirectToAction(nameof(Designer), new { id }); }
        var err = await api.RestoreAsync(CompanyId, id, versionNo, UserId);
        if (err is null) await audit.LogAsync("UTILITY", "PrintTemplates.Restore", $"Print template #{id}: version {versionNo} brought back into the draft.");
        TempData[err is null ? "SuccessMessage" : "ErrorMessage"] = err ?? $"Version {versionNo} is back in the draft. Publish it to make it live.";
        return RedirectToAction(nameof(Designer), new { id });
    }

    /// <summary>An image for an Image block (seal, accreditation logo): PNG or JPG up to 2 MB, kept in wwwroot/uploads/printtemplates.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    [RequestSizeLimit(3 * 1024 * 1024)]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> UploadImage(IFormFile? file)
    {
        if (!CanManage) return HoOnlyJson();
        if (file is null || file.Length == 0) return Json(new { success = false, error = "Choose an image." });
        if (file.Length > 2 * 1024 * 1024) return Json(new { success = false, error = "The image must be 2 MB or smaller." });
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (ext is not (".png" or ".jpg" or ".jpeg")) return Json(new { success = false, error = "Use a PNG or JPG image (it prints on bills and in the report PDF)." });
        var dir = Path.Combine(env.WebRootPath, "uploads", "printtemplates");
        Directory.CreateDirectory(dir);
        var fileName = $"{Guid.NewGuid():N}{ext}";
        await using (var fs = System.IO.File.Create(Path.Combine(dir, fileName)))
            await file.CopyToAsync(fs);
        return Json(new { success = true, url = $"/uploads/printtemplates/{fileName}" });
    }

    // ── Preview on real documents ────────────────────────────────────────────────────────────────────────

    /// <summary>The newest bill of the branch printed with this template's draft (LAB, or OPD with doc=opd).</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> PreviewBill(int id, int? branchId, string? doc)
    {
        var branch = branchId is > 0 ? branchId.Value : CurrentBranchId;
        using var con = db.CreateConnection();
        if (doc == "opd")
        {
            var opd = await con.ExecuteScalarAsync<int?>(
                "SELECT TOP 1 OPDServiceId FROM dbo.PatientOPDService WHERE BranchId = @branch AND IsActive = 1 AND OPDBillNo IS NOT NULL ORDER BY OPDServiceId DESC", new { branch });
            if (opd is null) return Content("This branch has no OPD bill yet to preview with.");
            return Redirect(Url.Action("PrintBill", "OPD", new { id = opd, previewTemplateId = id })!);
        }
        var lab = await con.ExecuteScalarAsync<int?>(
            "SELECT TOP 1 LabOrderId FROM dbo.LabOrder WHERE BranchId = @branch AND IsActive = 1 AND ISNULL(IsB2B, 0) = 0 ORDER BY LabOrderId DESC", new { branch });
        if (lab is null) return Content("This branch has no LAB bill yet to preview with.");
        return Redirect(Url.Action("PrintBill", "LabOrderBooking", new { labOrderId = lab, previewTemplateId = id })!);
    }

    /// <summary>The newest reported bill of the branch as a lab report PDF with this template's draft.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> PreviewReport(int id, int? branchId)
    {
        var branch = branchId is > 0 ? branchId.Value : CurrentBranchId;
        using var con = db.CreateConnection();
        var order = await con.ExecuteScalarAsync<int?>(@"
            SELECT TOP 1 lo.LabOrderId FROM dbo.LabOrder lo
            WHERE lo.BranchId = @branch AND lo.IsActive = 1
              AND EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.LabOrderId = lo.LabOrderId AND e.IsActive = 1 AND e.ReportStatusId IN (2, 3, 5)
                          AND ISNULL(e.Reporting_Type, 'Numeric') <> 'Image')
            ORDER BY CASE WHEN EXISTS (SELECT 1 FROM dbo.labentrydetails e WHERE e.LabOrderId = lo.LabOrderId AND e.ReportStatusId = 5) THEN 0 ELSE 1 END, lo.LabOrderId DESC",
            new { branch });
        if (order is null) return Content("This branch has no reported test yet to preview with.");
        try
        {
            var vm = await reportPdf.BuildAsync(order.Value, User);
            if (vm is null) return Content("The report could not be built for the preview.");
            // the preview always shows the header and footer, also for a branch that prints on pre-printed letterhead paper
            vm.ShowLetterhead = true;
            await reportPdf.ApplyPrintTemplateAsync(vm, User, CompanyId, id);
            var pdf = LabReportPdfDocument.Generate(vm, reportPdf.LoadLogo(vm.HospitalLogoPath), includeConditions: false);
            Response.Headers.ContentDisposition = $"inline; filename=\"preview-{vm.BillNo?.Replace('/', '-')}.pdf\"";
            return File(pdf, "application/pdf");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Print template {TemplateId}: report preview failed", id);
            return Content("The preview could not be made: " + ex.Message);
        }
    }
}
