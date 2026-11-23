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
/// Master &gt; Lab Master &gt; Phlebotomist Barcode Assignment (SQLScripts/2401) - pre-printed barcode series issued
/// to a phlebotomist (User Master, IsPhlebotomist = 1) of the current branch, consumed later from the phlebotomist app.
/// </summary>
[Authorize]
public class LabPhleboBarcodesController(ILabPhleboBarcodeApiClient api, IAuditLogService auditLogService) : Controller
{
    private const string NotEligible = "That user is not a phlebotomist of this branch.";

    private int BranchId => User.GetCurrentBranchId() ?? 0;

    private async Task<List<LabPhleboBarcodePhlebotomistModel>> PhlebotomistsAsync() =>
        (await api.GetPhlebotomistsAsync(User.GetCompanyId(), BranchId)).OrderBy(p => p.Name).ToList();

    private async Task<bool> IsEligibleAsync(int phlebotomistId) =>
        (await PhlebotomistsAsync()).Any(p => p.PhlebotomistId == phlebotomistId);

    [HttpGet]
    public async Task<IActionResult> Index(int? phlebotomistId = null)
    {
        try
        {
            var list = await PhlebotomistsAsync();
            var model = new LabPhleboBarcodeIndexViewModel
            {
                SelectedPhlebotomistId = phlebotomistId,
                PhlebotomistOptions = list.Select(p => new SelectListItem
                {
                    Value = p.PhlebotomistId.ToString(),
                    Text = $"{p.PhleboCode} - {p.Name}",
                    Selected = p.PhlebotomistId == phlebotomistId
                }).ToList()
            };
            if (phlebotomistId.HasValue)
            {
                var selected = list.FirstOrDefault(p => p.PhlebotomistId == phlebotomistId.Value);
                if (selected == null)
                {
                    TempData["ErrorMessage"] = NotEligible;
                    return RedirectToAction(nameof(Index));
                }
                model.SelectedPhlebotomistCode = selected.PhleboCode;
                model.SelectedPhlebotomistName = selected.Name;
            }
            return View(model);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetSeriesListJson(int phlebotomistId)
    {
        if (phlebotomistId <= 0) return Json(new { success = false, message = "A valid phlebotomist is required." });
        try
        {
            if (!await IsEligibleAsync(phlebotomistId)) return Json(new { success = false, message = NotEligible });
            var series = (await api.GetSeriesListAsync(BranchId, phlebotomistId)).ToList();
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
    public async Task<IActionResult> GenerateSeries([FromBody] LabPhleboBarcodeGenerateBody body)
    {
        if (body == null || body.PhlebotomistId <= 0) return Json(new { success = false, message = "A valid phlebotomist is required." });
        if (body.Quantity <= 0 || body.Quantity > 10000) return Json(new { success = false, message = "Quantity must be between 1 and 10000." });
        try
        {
            if (!await IsEligibleAsync(body.PhlebotomistId)) return Json(new { success = false, message = NotEligible });
            var result = await api.GenerateSeriesAsync(new LabPhleboBarcodeGenerateRequest(User.GetCompanyId(), BranchId,
                body.PhlebotomistId, body.Quantity, string.IsNullOrWhiteSpace(body.SampleCategoryCode) ? null : body.SampleCategoryCode, User.GetUserId()));

            var categoryText = string.IsNullOrWhiteSpace(result.SampleCategoryCode) ? "" : $" [{result.SampleCategoryCode}]";
            await auditLogService.LogAsync("LAB", "LAB.PhleboBarcodeSeriesGenerated",
                $"Generated phlebotomist barcode series {result.SeriesCode}{categoryText} ({result.StartBarcode} .. {result.EndBarcode}, {result.Quantity} codes) for user #{body.PhlebotomistId}.",
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
    public async Task<IActionResult> CancelSeries(int seriesId, [FromBody] LabPhleboBarcodeCancelBody body)
    {
        if (seriesId <= 0) return Json(new { success = false, message = "A valid series is required." });
        if (body == null || string.IsNullOrWhiteSpace(body.Reason)) return Json(new { success = false, message = "A cancellation reason is required." });
        try
        {
            await api.CancelSeriesAsync(seriesId, new LabPhleboBarcodeCancelRequest(BranchId, body.Reason, User.GetUserId()));
            await auditLogService.LogAsync("LAB", "LAB.PhleboBarcodeSeriesCancelled",
                $"Cancelled the remaining available codes of phlebotomist barcode series #{seriesId}. Reason: {body.Reason}", User.GetUserId());
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
        if (seriesId <= 0) return Json(new { success = false, message = "A valid series is required." });
        try
        {
            var barcodes = await api.GetSeriesBarcodesAsync(BranchId, seriesId);
            return Json(new { success = true, barcodes });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    /// <summary>The 25mm x 25mm label sheet of a series, the same layout as Franchise Barcode Assignment.</summary>
    [HttpGet]
    public async Task<IActionResult> PrintLabels(int seriesId)
    {
        if (seriesId <= 0) return BadRequest("Invalid Series.");
        var barcodes = (await api.GetSeriesBarcodesAsync(BranchId, seriesId)).ToList();
        if (barcodes.Count == 0) return NotFound("Series not found or has no barcodes.");

        ViewBag.FranchiseName = barcodes[0].PhlebotomistName ?? "Phlebotomist";
        ViewBag.FranchiseCode = "PB" + barcodes[0].PhlebotomistId.ToString("D4");
        ViewBag.SeriesCode = barcodes[0].SeriesCode ?? "";
        return View(barcodes.Select(b => b.BarcodeNo).ToList());
    }
}
