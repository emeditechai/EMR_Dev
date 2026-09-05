using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class SampleCollectionController(ISampleCollectionApiClient sampleCollectionApiClient) : Controller
    {
        [HttpGet]
        public async Task<IActionResult> Index(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var headerResult = await sampleCollectionApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search);

            var statuses = await sampleCollectionApiClient.GetStatusesAsync();

            var viewModel = new SampleCollectionDashboardViewModel
            {
                BranchId = branchId,
                FromDate = effectiveFrom,
                ToDate = effectiveTo,
                DateFilterType = dateFilterType ?? "BookingDate",
                StatusFilter = statusFilter ?? "All",
                Search = search,
                Stats = headerResult.Stats,
                Headers = headerResult.Headers,
                Statuses = statuses
            };

            return View(viewModel);
        }

        [HttpGet]
        public async Task<IActionResult> GetHeadersJson(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var headerResult = await sampleCollectionApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search);

            return Json(new
            {
                success = true,
                stats = headerResult.Stats,
                headers = headerResult.Headers
            });
        }

        [HttpGet]
        public async Task<IActionResult> GetDetailJson(int labOrderId)
        {
            if (labOrderId <= 0)
                return Json(new { success = false, message = "Invalid LabOrderId." });

            var detail = await sampleCollectionApiClient.GetDetailAsync(labOrderId);
            if (detail == null)
                return Json(new { success = false, message = "Sample collection order detail not found." });

            var statuses = await sampleCollectionApiClient.GetStatusesAsync();

            return Json(new
            {
                success = true,
                detail = detail,
                statuses = statuses
            });
        }

        [HttpPost]
        public async Task<IActionResult> UpdateStatusJson([FromBody] UpdateSampleCollectionStatusRequestDto request)
        {
            if (request == null || request.SampleCollectionId <= 0 || request.CollectionstatusID <= 0)
                return Json(new { success = false, message = "Invalid request parameters." });

            if (request.CollectionstatusID == 2 && request.LabOrderId.HasValue && request.LabOrderId.Value > 0)
            {
                var detail = await sampleCollectionApiClient.GetDetailAsync(request.LabOrderId.Value);
                if (detail != null)
                {
                    var bookingDate = (detail.BookingDateTime ?? detail.OrderDate).Date;
                    if (bookingDate != DateTime.Today)
                    {
                        return Json(new { success = false, message = $"Sample collection is only permitted on the booking date ({bookingDate:dd-MMM-yyyy})." });
                    }
                }
            }

            bool isSuccess = await sampleCollectionApiClient.UpdateStatusAsync(request);
            return Json(new
            {
                success = isSuccess,
                message = isSuccess ? "Status updated successfully." : "Failed to update status."
            });
        }

        [HttpPost]
        public async Task<IActionResult> UpdateProfileStatusJson([FromBody] UpdateProfileSampleCollectionStatusRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0 || request.CollectionstatusID <= 0 || (request.ProfileId == null && string.IsNullOrEmpty(request.ProfileName)))
                return Json(new { success = false, message = "Invalid profile request parameters." });

            if (request.CollectionstatusID == 2)
            {
                var detail = await sampleCollectionApiClient.GetDetailAsync(request.LabOrderId);
                if (detail != null)
                {
                    var bookingDate = (detail.BookingDateTime ?? detail.OrderDate).Date;
                    if (bookingDate != DateTime.Today)
                    {
                        return Json(new { success = false, message = $"Sample collection is only permitted on the booking date ({bookingDate:dd-MMM-yyyy})." });
                    }
                }
            }

            int count = await sampleCollectionApiClient.UpdateProfileStatusAsync(request);
            return Json(new
            {
                success = count > 0,
                count = count,
                message = count > 0 ? $"Updated {count} sample(s) for this profile." : "No samples were updated."
            });
        }

        [HttpPost]
        public async Task<IActionResult> CollectAllJson([FromBody] CollectAllSamplesRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid LabOrderId." });

            var detail = await sampleCollectionApiClient.GetDetailAsync(request.LabOrderId);
            if (detail != null)
            {
                var bookingDate = (detail.BookingDateTime ?? detail.OrderDate).Date;
                if (bookingDate != DateTime.Today)
                {
                    return Json(new { success = false, message = $"Sample collection is only permitted on the booking date ({bookingDate:dd-MMM-yyyy})." });
                }

                var pendingItems = detail.Items.Where(x => x.CollectionstatusID != 2).ToList();
                if (!pendingItems.Any())
                {
                    return Json(new { success = false, message = "All samples for this order are already collected." });
                }
            }

            int count = await sampleCollectionApiClient.CollectAllAsync(request.LabOrderId);
            return Json(new
            {
                success = count > 0,
                count = count,
                message = count > 0 ? $"{count} sample(s) marked as Collected." : "Failed to collect samples."
            });
        }

        [HttpGet]
        public async Task<IActionResult> PrintBarcode(int labOrderId, string? barcodeNo = null, int? sampleTypeId = null)
        {
            if (labOrderId <= 0)
                return BadRequest("Invalid LabOrderId.");

            var detail = await sampleCollectionApiClient.GetDetailAsync(labOrderId);
            if (detail == null)
                return NotFound("Lab order details not found.");

            var labels = new List<BarcodeLabelPrintViewModel>();

            // Only print labels for collected samples that have generated BarcodeNo
            var itemsQuery = detail.Items.Where(x => !string.IsNullOrEmpty(x.BarcodeNo));
            if (!string.IsNullOrEmpty(barcodeNo))
                itemsQuery = itemsQuery.Where(x => x.BarcodeNo == barcodeNo);
            if (sampleTypeId.HasValue && sampleTypeId > 0)
                itemsQuery = itemsQuery.Where(x => x.SampleTypeId == sampleTypeId.Value);

            var groups = itemsQuery.GroupBy(x => x.BarcodeNo!);

            foreach (var g in groups)
            {
                var first = g.First();
                labels.Add(new BarcodeLabelPrintViewModel
                {
                    LabOrderId = detail.LabOrderId,
                    BillNo = detail.BillNo,
                    TokenNo = detail.TokenNo,
                    PatientCode = detail.PatientCode,
                    PatientName = detail.PatientName,
                    Age = detail.Age,
                    Gender = detail.Gender,
                    BarcodeNo = g.Key,
                    SampleTypeName = first.SampleTypeName,
                    ContainerType = first.ContainerType,
                    CollectionDateTime = first.FormattedCollectionDateTime ?? DateTime.Now.ToString("dd-MMM-yyyy HH:mm"),
                    ProfileOrPackageName = first.ProfileName ?? first.PackageName ?? first.ProfileOrPackageName,
                    TestNames = g.Select(x => x.TestName).Distinct().ToList()
                });
            }

            return View("PrintBarcodeLabel", labels);
        }
    }
}
