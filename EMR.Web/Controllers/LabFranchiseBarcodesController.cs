using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

/// <summary>
/// Master &gt; Lab Master &gt; Franchise Barcode Assignment - pre-printed barcode series
/// for B2B Franchise billing. Only franchises with PreprintedBarcode = Yes ever appear here.
/// </summary>
[Authorize]
public class LabFranchiseBarcodesController(
    ILabFranchiseBarcodeApiClient barcodeApiClient,
    ILabFranchiseApiClient franchiseApiClient,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? franchiseId = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var eligible = (await franchiseApiClient.GetListAsync(isActive: true, companyId: companyId))
                .Where(f => f.PreprintedBarcode)
                .OrderBy(f => f.Franchise_Name)
                .ToList();

            var model = new LabFranchiseBarcodeIndexViewModel
            {
                SelectedFranchiseId = franchiseId,
                FranchiseOptions = eligible
                    .Select(f => new SelectListItem
                    {
                        Value = f.Franchise_ID.ToString(),
                        Text = $"{f.Franchise_Code} - {f.Franchise_Name}",
                        Selected = f.Franchise_ID == franchiseId
                    })
                    .ToList()
            };

            if (franchiseId.HasValue)
            {
                var selected = eligible.FirstOrDefault(f => f.Franchise_ID == franchiseId.Value);
                if (selected == null)
                {
                    TempData["ErrorMessage"] = "That franchise is not flagged for Preprinted Barcode, or does not belong to your company.";
                    return RedirectToAction(nameof(Index));
                }

                model.SelectedFranchiseCode = selected.Franchise_Code;
                model.SelectedFranchiseName = selected.Franchise_Name;
            }

            return View(model);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetSeriesListJson(int franchiseId)
    {
        if (franchiseId <= 0)
            return Json(new { success = false, message = "A valid franchise is required." });

        if (!await IsEligibleFranchiseAsync(franchiseId))
            return Json(new { success = false, message = "That franchise is not flagged for Preprinted Barcode, or does not belong to your company." });

        try
        {
            var series = (await barcodeApiClient.GetSeriesListAsync(franchiseId)).ToList();
            return Json(new
            {
                success = true,
                series,
                totalIssued = series.Sum(s => s.Quantity),
                totalAvailable = series.Sum(s => s.AvailableCount),
                totalUsed = series.Sum(s => s.UsedCount),
                totalVoided = series.Sum(s => s.VoidedCount)
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> GenerateSeries([FromBody] GenerateBarcodeSeriesRequestModel request)
    {
        if (request == null || request.Franchise_ID <= 0)
            return Json(new { success = false, message = "A valid franchise is required." });

        if (request.Quantity <= 0 || request.Quantity > 10000)
            return Json(new { success = false, message = "Quantity must be between 1 and 10000." });

        if (!await IsEligibleFranchiseAsync(request.Franchise_ID))
            return Json(new { success = false, message = "That franchise is not flagged for Preprinted Barcode, or does not belong to your company." });

        try
        {
            request.CreatedBy = User.GetUserId();
            var result = await barcodeApiClient.GenerateSeriesAsync(request);

            var categoryText = string.IsNullOrWhiteSpace(result.SampleCategoryCode) ? "" : $" [{result.SampleCategoryCode}]";
            await auditLogService.LogAsync(
                "LAB",
                "LAB.FranchiseBarcodeSeriesGenerated",
                $"Generated barcode series {result.SeriesCode}{categoryText} ({result.StartBarcode} .. {result.EndBarcode}, {result.Quantity} codes) for Franchise #{request.Franchise_ID}.",
                User.GetUserId());

            return Json(new { success = true, series = result });
        }
        catch (InvalidOperationException ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> CancelSeries(int seriesId, [FromBody] CancelBarcodeSeriesRequestModel request)
    {
        if (seriesId <= 0)
            return Json(new { success = false, message = "A valid series is required." });

        if (request == null || string.IsNullOrWhiteSpace(request.Reason))
            return Json(new { success = false, message = "A cancellation reason is required." });

        try
        {
            request.UserId = User.GetUserId();
            await barcodeApiClient.CancelSeriesAsync(seriesId, request);

            await auditLogService.LogAsync(
                "LAB",
                "LAB.FranchiseBarcodeSeriesCancelled",
                $"Cancelled the remaining available codes of barcode series #{seriesId}. Reason: {request.Reason}",
                User.GetUserId());

            return Json(new { success = true });
        }
        catch (InvalidOperationException ex)
        {
            return Json(new { success = false, message = ex.Message });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetSeriesBarcodesJson(int seriesId)
    {
        if (seriesId <= 0)
            return Json(new { success = false, message = "A valid series is required." });

        try
        {
            var barcodes = await barcodeApiClient.GetSeriesBarcodesAsync(seriesId);
            return Json(new { success = true, barcodes });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    /// <summary>
    /// Prints the label sheet for a freshly generated series - the physical stickers to ship to the
    /// franchise. A dedicated 25mm x 25mm (1" x 1") thermal-label layout, one barcode per physical
    /// label, not the 50mm x 28mm A4-sheet vial-label view Sample Collection uses.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> PrintLabels(int seriesId)
    {
        if (seriesId <= 0)
            return BadRequest("Invalid Series.");

        var barcodes = (await barcodeApiClient.GetSeriesBarcodesAsync(seriesId)).ToList();
        if (barcodes.Count == 0)
            return NotFound("Series not found or has no barcodes.");

        ViewBag.FranchiseName = barcodes[0].Franchise_Name ?? "Franchise";
        ViewBag.FranchiseCode = barcodes[0].Franchise_Code ?? "";
        ViewBag.SeriesCode = barcodes[0].SeriesCode ?? "";

        var barcodeNumbers = barcodes.Select(b => b.BarcodeNo).ToList();
        return View(barcodeNumbers);
    }

    private async Task<bool> IsEligibleFranchiseAsync(int franchiseId)
    {
        var companyId = User.GetCompanyId();
        var franchise = await franchiseApiClient.GetByIdAsync(franchiseId);
        return franchise != null && franchise.PreprintedBarcode && franchise.CompanyId == companyId;
    }
}
