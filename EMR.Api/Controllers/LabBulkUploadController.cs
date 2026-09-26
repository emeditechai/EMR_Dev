using EMR.Api.Models;
using EMR.Api.Services;
using EMR.Api.Services.BulkUpload;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Excel bulk upload for lab masters: template download (blank or with existing data) and import.</summary>
[ApiController]
[Route("api/lab-bulk-upload")]
public class LabBulkUploadController(ILabBulkUploadService service) : ControllerBase
{
    private const string XlsxContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    [HttpGet("{module}/template")]
    [ProducesResponseType(typeof(FileContentResult), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> Template(
        string module,
        [FromQuery] bool withData,
        [FromQuery] int companyId = 1,
        [FromQuery] int? branchId = null,
        [FromQuery] bool isHO = true)
    {
        if (!service.IsSupported(module))
            return NotFound(ApiResponse<object>.Fail($"Unknown bulk upload module '{module}'."));

        var ctx = new BulkContext { CompanyId = companyId, BranchId = branchId, IsHO = isHO };
        var (content, fileName) = await service.BuildTemplateAsync(module, withData, ctx);
        return File(content, XlsxContentType, fileName);
    }

    [HttpPost("{module}/import")]
    [RequestSizeLimit(20_000_000)]
    [ProducesResponseType(typeof(ApiResponse<LabBulkUploadResult>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Import(
        string module,
        IFormFile? file,
        [FromForm] bool dryRun,
        [FromForm] int companyId = 1,
        [FromForm] int? userId = null,
        [FromForm] int? branchId = null,
        [FromForm] bool isHO = true)
    {
        if (!service.IsSupported(module))
            return NotFound(ApiResponse<object>.Fail($"Unknown bulk upload module '{module}'."));
        if (file == null || file.Length == 0)
            return BadRequest(ApiResponse<object>.Fail("Please choose an Excel (.xlsx) file."));
        if (!file.FileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
            return BadRequest(ApiResponse<object>.Fail("Only .xlsx files are supported. Use the template downloaded from this screen."));

        var ctx = new BulkContext { CompanyId = companyId, UserId = userId, BranchId = branchId, IsHO = isHO, DryRun = dryRun };
        await using var stream = new MemoryStream();
        await file.CopyToAsync(stream);
        stream.Position = 0;

        var result = await service.ImportAsync(module, stream, ctx);
        return Ok(ApiResponse<LabBulkUploadResult>.Ok(result, result.FileError ?? "Upload processed."));
    }
}
