using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Pre-Printed Barcode series/pool for B2B Franchise billing (Master &gt; Lab Master &gt; Franchise Barcode Assignment).</summary>
[ApiController]
[Route("api/lab-franchise-barcode")]
public class LabFranchiseBarcodeController(ILabFranchiseBarcodeService service, ILogger<LabFranchiseBarcodeController> logger) : ControllerBase
{
    [HttpGet("series/{franchiseId:int}")]
    public async Task<IActionResult> GetSeriesList(int franchiseId)
    {
        try
        {
            var items = await service.GetSeriesListAsync(franchiseId);
            return Ok(items);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching barcode series for Franchise #{FranchiseId}", franchiseId);
            return StatusCode(500, new { message = "An internal error occurred while fetching the barcode series." });
        }
    }

    [HttpPost("series/generate")]
    public async Task<IActionResult> GenerateSeries([FromBody] GenerateBarcodeSeriesRequestModel request)
    {
        try
        {
            var result = await service.GenerateSeriesAsync(request);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while generating a barcode series for Franchise #{FranchiseId}", request.Franchise_ID);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPost("series/{seriesId:int}/cancel")]
    public async Task<IActionResult> CancelSeries(int seriesId, [FromBody] CancelBarcodeSeriesRequestModel request)
    {
        try
        {
            await service.CancelSeriesAsync(seriesId, request);
            return Ok(new { message = "Series cancelled successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while cancelling barcode series #{SeriesId}", seriesId);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpGet("series/{seriesId:int}/barcodes")]
    public async Task<IActionResult> GetSeriesBarcodes(int seriesId)
    {
        try
        {
            var items = await service.GetSeriesBarcodesAsync(seriesId);
            return Ok(items);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching barcodes for series #{SeriesId}", seriesId);
            return StatusCode(500, new { message = "An internal error occurred while fetching the barcodes." });
        }
    }

    [HttpGet("pool/{franchiseId:int}/available-count")]
    public async Task<IActionResult> GetAvailableCount(int franchiseId)
    {
        try
        {
            var count = await service.GetAvailableCountAsync(franchiseId);
            return Ok(new { franchiseId, availableCount = count });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while counting available barcodes for Franchise #{FranchiseId}", franchiseId);
            return StatusCode(500, new { message = "An internal error occurred while counting available barcodes." });
        }
    }

    [HttpGet("pool/status")]
    public async Task<IActionResult> GetBarcodeStatus([FromQuery] string barcodeNo)
    {
        if (string.IsNullOrWhiteSpace(barcodeNo))
            return BadRequest(new { message = "barcodeNo is required." });

        try
        {
            var item = await service.GetBarcodeStatusAsync(barcodeNo);
            if (item == null)
                return NotFound(new { message = "Barcode not found." });

            return Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while looking up barcode {BarcodeNo}", barcodeNo);
            return StatusCode(500, new { message = "An internal error occurred while looking up the barcode." });
        }
    }

    [HttpPost("pool/validate-consume")]
    public async Task<IActionResult> ValidateConsume([FromBody] ValidateConsumeBarcodeRequestModel request)
    {
        try
        {
            var result = await service.ValidateAndConsumeAsync(request);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while validating barcode {BarcodeNo} for LabOrder #{LabOrderId}", request.BarcodeNo, request.LabOrderId);
            return StatusCode(500, new { message = "An internal error occurred while validating the barcode." });
        }
    }
}
