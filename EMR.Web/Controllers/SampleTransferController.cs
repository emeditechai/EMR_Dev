using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class SampleTransferController(
        ISampleTransferApiClient sampleTransferApiClient,
        ILabOrderApiClient labOrderApiClient,
        IAuditLogService auditLogService,
        ApplicationDbContext dbContext) : Controller
    {
        [HttpGet]
        public async Task<IActionResult> Index(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
            string? transferStatusFilter = "Ready",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
            string? branchName = User.FindFirstValue("BranchName") ?? "Current Branch";

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today.AddDays(-7); // Default to last 7 days so collected samples are immediately visible
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var listResult = await sampleTransferApiClient.GetEligibleSamplesAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, transferStatusFilter, search, departmentId, categoryId, subCategoryId);

            var targetBranches = await sampleTransferApiClient.GetTargetBranchesAsync(branchId);

            var departments = await labOrderApiClient.GetDepartmentsAsync();
            var departmentOptions = departments
                .Select(x => new SelectListItem { Value = x.DepartmentId.ToString(), Text = x.DepartmentName })
                .ToList();

            var categories = await labOrderApiClient.GetCategoriesAsync(departmentId);
            var categoryOptions = categories
                .Select(x => new SelectListItem { Value = x.CategoryId.ToString(), Text = x.CategoryName })
                .ToList();

            var subCategories = await labOrderApiClient.GetSubCategoriesAsync(categoryId);
            var subCategoryOptions = subCategories
                .Select(x => new SelectListItem { Value = x.SubCategoryId.ToString(), Text = x.SubCategoryName })
                .ToList();

            var receivableResult = await sampleTransferApiClient.GetReceivableSamplesAsync(branchId, null, null);

            var viewModel = new SampleTransferDashboardViewModel
            {
                BranchId = branchId,
                BranchName = branchName,
                FromDate = effectiveFrom,
                ToDate = effectiveTo,
                DateFilterType = dateFilterType ?? "CollectionDate",
                TransferStatusFilter = transferStatusFilter ?? "Ready",
                Search = search,
                DepartmentId = departmentId,
                CategoryId = categoryId,
                SubCategoryId = subCategoryId,
                DepartmentOptions = departmentOptions,
                CategoryOptions = categoryOptions,
                SubCategoryOptions = subCategoryOptions,
                Stats = listResult.Stats,
                ReceiveStats = receivableResult?.Stats ?? new SampleTransferReceiveStatsDto(),
                Items = listResult.Items,
                TargetBranches = targetBranches.Select(b => new SelectListItem
                {
                    Value = b.BranchId.ToString(),
                    Text = $"{b.BranchCode} - {b.BranchName}"
                }).ToList()
            };

            return View(viewModel);
        }

        [HttpGet]
        public async Task<IActionResult> GetCategoriesForDropdown(int? departmentId)
        {
            var categories = await labOrderApiClient.GetCategoriesAsync(departmentId);
            return Json(categories.Select(c => new { value = c.CategoryId, text = c.CategoryName }));
        }

        [HttpGet]
        public async Task<IActionResult> GetSubCategoriesForDropdown(int? categoryId)
        {
            var subCategories = await labOrderApiClient.GetSubCategoriesAsync(categoryId);
            return Json(subCategories.Select(s => new { value = s.SubCategoryId, text = s.SubCategoryName }));
        }

        [HttpGet]
        public async Task<IActionResult> GetEligibleSamplesJson(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
            string? transferStatusFilter = "Ready",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var effectiveFrom = fromDate;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : toDate;

            var result = await sampleTransferApiClient.GetEligibleSamplesAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, transferStatusFilter, search, departmentId, categoryId, subCategoryId);

            return Json(new { success = true, data = result });
        }

        [HttpPost]
        public async Task<IActionResult> ExecuteTransferJson([FromBody] ExecuteSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return Json(new { success = false, message = "No samples selected for transfer." });

            if (request.TargetBranchId <= 0)
                return Json(new { success = false, message = "Please select a valid destination/target branch." });

            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
            request.SourceBranchId = branchId;
            request.UserId = User.GetUserId();

            if (request.SourceBranchId == request.TargetBranchId)
                return Json(new { success = false, message = "Source and target branch cannot be the same." });

            try
            {
                var result = await sampleTransferApiClient.ExecuteTransferAsync(request);
                if (result.IsSuccess)
                {
                    await auditLogService.LogActivityAsync(
                        eventType: "Sample Transfer",
                        actionName: "LAB.SampleTransferred",
                        description: $"Transferred {result.TransferredCount} samples from branch {branchId} to target branch {request.TargetBranchId}. Remarks: {request.TransferRemarks}",
                        userId: User.GetUserId(),
                        branchId: branchId,
                        moduleCode: "LAB"
                    );
                }

                return Json(new
                {
                    success = result.IsSuccess,
                    transferredCount = result.TransferredCount,
                    message = result.Message,
                    processedIds = string.Join(",", request.SampleCollectionIds)
                });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> GetHistoryJson(
            string? mode = "Outgoing",
            DateTime? fromDate = null,
            DateTime? toDate = null,
            string? search = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : toDate;

            var list = await sampleTransferApiClient.GetTransferHistoryAsync(
                branchId, mode, fromDate, effectiveTo, search);

            return Json(new { success = true, data = list });
        }

        [HttpGet]
        public async Task<IActionResult> GetReceivableSamplesJson(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "ReceivedDate",
            string? receiveStatusFilter = "Pending",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var effectiveFrom = fromDate;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : toDate;

            var result = await sampleTransferApiClient.GetReceivableSamplesAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, receiveStatusFilter, search, departmentId, categoryId, subCategoryId);

            return Json(new { success = true, data = result });
        }

        [HttpPost]
        public async Task<IActionResult> ExecuteReceiveJson([FromBody] ReceiveSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return Json(new { success = false, message = "No samples selected for receiving." });

            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
            request.TargetBranchId = branchId;
            request.UserId = User.GetUserId();

            try
            {
                var result = await sampleTransferApiClient.ExecuteReceiveAsync(request);
                if (result.IsSuccess)
                {
                    await auditLogService.LogActivityAsync(
                        eventType: "Sample Receive",
                        actionName: "LAB.SampleReceived",
                        description: $"Received {result.ReceivedCount} samples at branch {branchId}. Remarks: {request.ReceiveRemarks}",
                        userId: User.GetUserId(),
                        branchId: branchId,
                        moduleCode: "LAB"
                    );
                }

                return Json(new
                {
                    success = result.IsSuccess,
                    receivedCount = result.ReceivedCount,
                    message = result.Message,
                    processedIds = string.Join(",", request.SampleCollectionIds)
                });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> PrintWorksheet(string ids, string mode = "Transfer")
        {
            if (string.IsNullOrWhiteSpace(ids))
                return Content("No samples provided for printing.");

            var items = await sampleTransferApiClient.GetWorksheetDataAsync(ids);

            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
            var settings = await dbContext.HospitalSettings
                .Where(s => s.BranchId == branchId && s.IsActive)
                .FirstOrDefaultAsync()
                ?? await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.IsActive);
            
            ViewBag.PrintMode = mode; // "Transfer" or "Receive"
            ViewBag.PrintDate = DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt");
            ViewBag.PrintedBy = User.GetDisplayName();
            ViewBag.Settings = settings;
            ViewBag.BranchName = User.FindFirstValue("BranchName");

            return View(items);
        }
    }
}
