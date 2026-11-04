using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Pre-printed tube barcodes of phlebotomists (Master &gt; Lab Master &gt; Phlebotomist Barcode Assignment, SQLScripts/2401).
/// validate-consume is for the phlebotomist app.</summary>
[ApiController]
[Route("api/lab-phlebo-barcode")]
public class LabPhleboBarcodeController(ILabPhleboBarcodeService service, ILogger<LabPhleboBarcodeController> logger) : ControllerBase
{
    [HttpGet("phlebotomists")]
    public async Task<IActionResult> Phlebotomists([FromQuery] int companyId, [FromQuery] int branchId) =>
        Ok(await service.GetPhlebotomistsAsync(companyId, branchId));

    [HttpGet("series")]
    public async Task<IActionResult> SeriesList([FromQuery] int branchId, [FromQuery] int phlebotomistId) =>
        Ok(await service.GetSeriesListAsync(branchId, phlebotomistId));

    [HttpPost("series/generate")]
    public async Task<IActionResult> Generate([FromBody] LabPhleboBarcodeGenerateRequest request)
    {
        try { return Ok(await service.GenerateAsync(request)); }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Phlebotomist barcode series not generated for user #{Id}", request.PhlebotomistId);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPost("series/{seriesId:int}/cancel")]
    public async Task<IActionResult> Cancel(int seriesId, [FromBody] LabPhleboBarcodeCancelRequest request)
    {
        try { await service.CancelAsync(seriesId, request); return Ok(new { message = "Series cancelled." }); }
        catch (Exception ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpGet("series/{seriesId:int}/barcodes")]
    public async Task<IActionResult> Barcodes(int seriesId, [FromQuery] int branchId) =>
        Ok(await service.GetBarcodesAsync(branchId, seriesId));

    [HttpPost("validate-consume")]
    public async Task<IActionResult> ValidateConsume([FromBody] LabPhleboBarcodeConsumeRequest request)
    {
        var (ok, message) = await service.ValidateConsumeAsync(request);
        return Ok(new { success = ok, message });
    }
}
