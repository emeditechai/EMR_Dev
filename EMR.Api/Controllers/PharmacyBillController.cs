using EMR.Api.Models;
using EMR.Api.Services.BillReader;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record PhBillLearnRequest(int CompanyId, int? SupplierId, string Pairs);

/// <summary>Pharmacy > Purchase Order / GRN "Read bill" (SQLScripts/2367): a supplier's bill (PDF / JPG / PNG) read on the server.</summary>
[ApiController]
[Route("api/pharmacy/bill")]
[Produces("application/json")]
public class PharmacyBillController(IBillReaderService reader, ILogger<PharmacyBillController> logger) : ControllerBase
{
    private static readonly string[] Allowed = [".pdf", ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"];

    [HttpPost("read")]
    [RequestSizeLimit(15 * 1024 * 1024)]
    public async Task<IActionResult> Read([FromForm] int companyId, [FromForm] int branchId, IFormFile? file, CancellationToken ct)
    {
        if (file == null || file.Length == 0) return BadRequest(ApiResponse<object>.Fail("Choose the bill (PDF or photo)."));
        if (!Allowed.Contains(Path.GetExtension(file.FileName).ToLowerInvariant())) return BadRequest(ApiResponse<object>.Fail("The bill must be a PDF or a photo (JPG / PNG)."));
        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, ct);
        try
        {
            return Ok(ApiResponse<BillReadResult>.Ok(await reader.ReadAsync(companyId, branchId, ms.ToArray(), file.FileName, ct)));
        }
        catch (InvalidOperationException ex) { return BadRequest(ApiResponse<object>.Fail(ex.Message)); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Bill could not be read: {File}", file.FileName);
            return BadRequest(ApiResponse<object>.Fail("The bill could not be read. Try a clearer photo or the PDF from the supplier."));
        }
    }

    [HttpPost("learn")]
    public async Task<IActionResult> Learn([FromBody] PhBillLearnRequest r) =>
        Ok(ApiResponse<int>.Ok(await reader.LearnAsync(r.CompanyId, r.SupplierId, r.Pairs ?? "[]")));
}
