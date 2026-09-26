using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Excel bulk upload used by the modal on the lab master Index pages (see _LabBulkUploadModal).</summary>
[Authorize]
public class LabBulkUploadController(ILabBulkUploadApiClient api, ApplicationDbContext dbContext) : Controller
{
    private static readonly HashSet<string> Modules =
        new(["test-method", "sub-category", "investigation", "franchise", "b2c-rate", "b2b-rate"], StringComparer.OrdinalIgnoreCase);

    private bool CheckIsHOBranch()
    {
        var sessionVal = HttpContext.Session.GetString("IsHOBranch");
        if (!string.IsNullOrEmpty(sessionVal) && bool.TryParse(sessionVal, out var isHOSession))
            return isHOSession;

        if (User.IsHOBranch())
            return true;

        var currentBranchId = User.GetCurrentBranchId();
        if (currentBranchId.HasValue)
        {
            var branch = dbContext.BranchMasters.Find(currentBranchId.Value);
            return branch?.IsHOBranch == true;
        }
        return false;
    }

    [HttpGet]
    public async Task<IActionResult> Template(string module, bool withData = false)
    {
        if (!Modules.Contains(module)) return NotFound();

        try
        {
            var (content, fileName) = await api.DownloadTemplateAsync(module, withData, User.GetCompanyId(), User.GetCurrentBranchId(), CheckIsHOBranch());
            return File(content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            TempData["ErrorMessage"] = $"Could not generate the template: {ex.Message}";
            var referer = Request.Headers.Referer.ToString();
            return Url.IsLocalUrl(referer) || referer.StartsWith($"{Request.Scheme}://{Request.Host}/")
                ? Redirect(referer)
                : Content(TempData["ErrorMessage"]!.ToString()!, "text/plain");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(20_000_000)]
    public async Task<IActionResult> Import(string module, IFormFile? file, bool dryRun = false)
    {
        if (!Modules.Contains(module))
            return Json(new { success = false, message = "Unknown module." });
        if (file == null || file.Length == 0)
            return Json(new { success = false, message = "Please choose the Excel (.xlsx) file to upload." });
        if (!file.FileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
            return Json(new { success = false, message = "Only .xlsx files are supported. Download the template from this screen." });

        try
        {
            await using var stream = file.OpenReadStream();
            var result = await api.ImportAsync(module, stream, file.FileName, dryRun, User.GetCompanyId(), User.GetUserId(),
                                               User.GetCurrentBranchId(), CheckIsHOBranch());
            return Json(new { success = result.FileError == null, message = result.FileError, data = result });
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            return Json(new { success = false, message = $"Upload failed: {ex.Message}" });
        }
    }
}
