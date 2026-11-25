using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Excel bulk upload on Doctor Master (Doctors/Index): referral doctors and OPD / IPD doctors.
/// Own endpoints so the permission is MASTER.DOCTORS:IMPORT, not the lab masters' (SQLScripts/2556).
/// </summary>
[Authorize]
public class DoctorBulkUploadController(ILabBulkUploadApiClient api, ApplicationDbContext dbContext, IAuditLogService auditLogService) : Controller
{
    private static readonly Dictionary<string, string> Modules = new(StringComparer.OrdinalIgnoreCase)
    {
        ["doctor-referral"] = "referral doctors",
        ["doctor-opd-ipd"] = "OPD / IPD doctors"
    };

    /// <summary>Same rule as the Doctor form: several branches only for an Administrator / super admin at the Head Office branch.</summary>
    private async Task<bool> CanAssignMultipleBranchesAsync()
    {
        if (!string.Equals(User.GetActiveRole(), "Administrator", StringComparison.OrdinalIgnoreCase) && !User.IsSuperAdmin())
            return false;
        var branchId = User.GetCurrentBranchId();
        return branchId.HasValue && await dbContext.BranchMasters.AsNoTracking().AnyAsync(b => b.BranchId == branchId.Value && b.IsHOBranch);
    }

    [HttpGet]
    public async Task<IActionResult> Template(string module, bool withData = false)
    {
        if (!Modules.ContainsKey(module)) return NotFound();
        if (User.GetCurrentBranchId() is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        try
        {
            var (content, fileName) = await api.DownloadTemplateAsync(module, withData, User.GetCompanyId(), User.GetCurrentBranchId(), await CanAssignMultipleBranchesAsync());
            return File(content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            TempData["Error"] = $"Could not generate the template: {ex.Message}";
            return RedirectToAction("Index", "Doctors");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(20_000_000)]
    public async Task<IActionResult> Import(string module, IFormFile? file, bool dryRun = false)
    {
        if (!Modules.TryGetValue(module, out var what))
            return Json(new { success = false, message = "Unknown module." });
        if (User.GetCurrentBranchId() is null)
            return Json(new { success = false, message = "Please select a branch first." });
        if (file == null || file.Length == 0)
            return Json(new { success = false, message = "Please choose the Excel (.xlsx) file to upload." });
        if (!file.FileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
            return Json(new { success = false, message = "Only .xlsx files are supported. Download the template from this screen." });

        try
        {
            await using var stream = file.OpenReadStream();
            var result = await api.ImportAsync(module, stream, file.FileName, dryRun, User.GetCompanyId(), User.GetUserId(),
                                               User.GetCurrentBranchId(), await CanAssignMultipleBranchesAsync());
            if (!dryRun && result.FileError == null && result.Inserted + result.Updated > 0)
                await auditLogService.LogAsync("MasterData", "Doctors.BulkUpload",
                    $"Bulk upload of {what} ({file.FileName}): {result.Inserted} added, {result.Updated} updated, {result.Failed} failed, {result.Unchanged} unchanged");
            return Json(new { success = result.FileError == null, message = result.FileError, data = result });
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            return Json(new { success = false, message = $"Upload failed: {ex.Message}" });
        }
    }
}
