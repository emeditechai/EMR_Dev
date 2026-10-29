using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// LAB > External Document Upload (SQLScripts/2354). For an active lab booking of the current branch, uploads the
/// external document of each test marked "Has External Document" to the FTP server set in Hospital Settings > Lab:
/// &lt;Root&gt;/&lt;Company&gt;/&lt;Branch&gt;/&lt;yyyy-MM-dd&gt;/&lt;BranchId&gt;_&lt;LabOrderId&gt;_&lt;Test_ID&gt;.&lt;ext&gt;, and records it in
/// LabExternalDocument. Cancelled bookings and cancelled tests are never offered.
/// </summary>
[Authorize]
public class LabExternalDocumentsController(
    IDbConnectionFactory db,
    ILabFtpService ftp,
    IAuditLogService auditLogService,
    ILogger<LabExternalDocumentsController> logger) : Controller
{
    private const long MaxBytes = 20 * 1024 * 1024;
    private static readonly string[] Allowed = [".pdf", ".jpg", ".jpeg", ".png", ".doc", ".docx"];

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("SelectBranch", "Account");
        ViewBag.FtpReady = await ftp.GetForBranchAsync(User.GetCompanyId(), branchId.Value) is { } s
                           && !string.IsNullOrEmpty(s.Host) && !string.IsNullOrEmpty(s.PasswordEnc);
        return View();
    }

    /// <summary>Active bookings of the day (and filters) having at least one external-document test.</summary>
    [HttpGet]
    public async Task<IActionResult> Bookings(DateTime? date, string? mobile, string? name, string? billNo)
    {
        if (date is null) return Json(new { success = false, message = "Choose the booking date." });
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "Select a branch first." });
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync("dbo.usp_Lab_ExternalDoc_SearchBookings",
            new { BranchId = branchId, Date = date.Value.Date, Mobile = mobile, Name = name, BillNo = billNo },
            commandType: System.Data.CommandType.StoredProcedure);
        return Json(new { success = true, rows });
    }

    /// <summary>The booking's external-document tests and their current uploads.</summary>
    [HttpGet]
    public async Task<IActionResult> Tests(int labOrderId)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "Select a branch first." });
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_Lab_ExternalDoc_GetTests",
            new { BranchId = branchId, LabOrderId = labOrderId }, commandType: System.Data.CommandType.StoredProcedure);
        var booking = await grid.ReadFirstOrDefaultAsync();
        var tests = await grid.ReadAsync();
        return booking is null
            ? Json(new { success = false, message = "This booking is cancelled or not of your branch." })
            : Json(new { success = true, booking, tests });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(MaxBytes + 1024 * 1024)]
    public async Task<IActionResult> Upload(int labOrderId, int testId, IFormFile? file)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Select a branch first.");
        if (file is null || file.Length == 0) return Fail("Choose the file to upload.");
        if (file.Length > MaxBytes) return Fail("The file is larger than 20 MB.");
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (!Allowed.Contains(ext)) return Fail("Upload a PDF, JPG, PNG, DOC or DOCX file.");
        if (!await LooksLikeAsync(file, ext)) return Fail($"The file content is not a valid {ext.TrimStart('.').ToUpperInvariant()} file.");

        var companyId = User.GetCompanyId();
        var settings = await ftp.GetForBranchAsync(companyId, branchId.Value);
        if (settings is null || string.IsNullOrEmpty(settings.PasswordEnc))
            return Fail("FTP is not set up. Enter the FTP credentials in Hospital Settings > Lab.");

        using var con = db.CreateConnection();
        // the test must still be an active external-document test of an active booking of this branch
        var item = await con.QueryFirstOrDefaultAsync<int?>(
            @"SELECT TOP 1 v.LabOrderItemId FROM dbo.vw_LabExternalDocTest v JOIN dbo.LabOrder lo ON lo.LabOrderId = v.LabOrderId
               WHERE v.LabOrderId = @labOrderId AND v.Test_ID = @testId AND lo.BranchId = @branchId AND lo.IsActive = 1",
            new { labOrderId, testId, branchId });
        if (item is null) return Fail("This test is cancelled, not on the booking, or the booking is not of your branch.");

        var names = await con.QueryFirstAsync<(string Company, string Branch)>(
            @"SELECT ISNULL((SELECT CompanyName FROM dbo.CompanyMaster WHERE CompanyId = @companyId), 'Company'),
                     ISNULL((SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @branchId), 'Branch')",
            new { companyId, branchId });

        var fileName = $"{branchId}_{labOrderId}_{testId}{ext}";
        string path;
        try
        {
            await using var stream = file.OpenReadStream();
            path = await ftp.UploadAsync(settings, [names.Company, names.Branch, DateTime.Today.ToString("yyyy-MM-dd")],
                fileName, stream, HttpContext.RequestAborted);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "External document upload for order {Order} test {Test} failed", labOrderId, testId);
            return Fail("Upload to the FTP server failed: " + ex.Message);
        }

        await con.ExecuteAsync("dbo.usp_Lab_ExternalDoc_Save", new
        {
            CompanyId = companyId, BranchId = branchId, LabOrderId = labOrderId, InvestigationId = testId, LabOrderItemId = item,
            OriginalFileName = Path.GetFileName(file.FileName), FileName = fileName, FilePath = path,
            FileSizeBytes = file.Length, ContentType = file.ContentType, UserId = User.GetUserId()
        }, commandType: System.Data.CommandType.StoredProcedure);

        await auditLogService.LogAsync("Lab External Document", "Upload",
            $"External document for booking #{labOrderId}, test #{testId} uploaded to {path}", User.GetUserId(), branchId.Value);
        return Json(new { success = true, message = "Uploaded.", path, fileName });
    }

    /// <summary>The file's first bytes match its extension (PDF, JPEG, PNG, DOC, DOCX).</summary>
    private static async Task<bool> LooksLikeAsync(IFormFile file, string ext)
    {
        var h = new byte[8];
        await using var s = file.OpenReadStream();
        var n = await s.ReadAsync(h.AsMemory(0, h.Length));
        if (n < 4) return false;
        return ext switch
        {
            ".pdf" => h[0] == 0x25 && h[1] == 0x50 && h[2] == 0x44 && h[3] == 0x46,                        // %PDF
            ".png" => h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47,
            ".jpg" or ".jpeg" => h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF,
            ".docx" => h[0] == 0x50 && h[1] == 0x4B,                                                     // zip
            ".doc" => h[0] == 0xD0 && h[1] == 0xCF && h[2] == 0x11 && h[3] == 0xE0,                      // OLE
            _ => false
        };
    }

    private JsonResult Fail(string message) => Json(new { success = false, message });
}
