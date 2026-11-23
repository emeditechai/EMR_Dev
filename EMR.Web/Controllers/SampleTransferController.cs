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
using Dapper;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class SampleTransferController(
        ISampleTransferApiClient sampleTransferApiClient,
        ILabOrderApiClient labOrderApiClient,
        IAuditLogService auditLogService,
        ApplicationDbContext dbContext) : Controller
    {
        /// <summary>A franchise login sees and moves only the samples of the bills it created or that are for its own
        /// franchise (SQLScripts/2264); every other login: all samples of the branch (null).</summary>
        private int? OwnSamplesOnly => User.IsFranchiseUser() ? User.GetUserId() : null;

        /// <summary>Samples of tests whose category needs no sample (e.g. Radiology): nothing to transfer (SQLScripts/2265).</summary>
        private async Task<bool> HasNoSampleTestsAsync(IEnumerable<long> sampleCollectionIds)
        {
            var ids = sampleCollectionIds.Distinct().ToArray();
            return await dbContext.Database.GetDbConnection().ExecuteScalarAsync<int>(@"
                SELECT COUNT(1)
                FROM dbo.SampleCollection sc
                LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
                JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = ISNULL(lim.Category_ID, sc.TestcategoryID)
                WHERE sc.samplecollectionID IN @ids AND c.Is_Sample_Collection_Required = 0", new { ids }) > 0;
        }

        /// <summary>False when a franchise login names a sample that is not its own.</summary>
        private async Task<bool> MayMoveAsync(IEnumerable<long> sampleCollectionIds)
        {
            if (OwnSamplesOnly is not int userId) return true;
            var ids = sampleCollectionIds.Distinct().ToArray();
            var own = await dbContext.Database.GetDbConnection().ExecuteScalarAsync<int>(@"
                SELECT COUNT(DISTINCT sc.samplecollectionID)
                FROM dbo.SampleCollection sc
                JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
                WHERE sc.samplecollectionID IN @ids
                  AND (lo.CreatedBy = @userId OR (lo.AgentType = 'F' AND lo.B2BAgentID = @franchiseId))",
                new { ids, userId, franchiseId = User.GetFranchiseId() });
            return own == ids.Length;
        }

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
            var effectiveFrom = fromDate ?? today;   // opens on today's samples; the date filters widen it
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var listResult = await sampleTransferApiClient.GetEligibleSamplesAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, transferStatusFilter, search, departmentId, categoryId, subCategoryId, OwnSamplesOnly);

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

            var receivableResult = await sampleTransferApiClient.GetReceivableSamplesAsync(branchId, today, today.AddDays(1).AddSeconds(-1), createdBy: OwnSamplesOnly);

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
                branchId, effectiveFrom, effectiveTo, dateFilterType, transferStatusFilter, search, departmentId, categoryId, subCategoryId, OwnSamplesOnly);

            return Json(new { success = true, data = result });
        }

        [HttpPost]
        public async Task<IActionResult> ExecuteTransferJson([FromBody] ExecuteSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return Json(new { success = false, message = "No samples selected for transfer." });

            if (request.TargetBranchId <= 0)
                return Json(new { success = false, message = "Please select a valid destination/target branch." });
            if (!await MayMoveAsync(request.SampleCollectionIds.Select(x => (long)x)))
                return Json(new { success = false, message = "One or more selected samples are not available to you." });
            if (await HasNoSampleTestsAsync(request.SampleCollectionIds))
                return Json(new { success = false, message = "One or more selected tests need no sample collection (e.g. Radiology) and cannot be transferred." });

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
                branchId, mode, fromDate, effectiveTo, search, OwnSamplesOnly);

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
                branchId, effectiveFrom, effectiveTo, dateFilterType, receiveStatusFilter, search, departmentId, categoryId, subCategoryId, OwnSamplesOnly);

            return Json(new { success = true, data = result });
        }

        [HttpPost]
        public async Task<IActionResult> ExecuteReceiveJson([FromBody] ReceiveSampleTransferRequestDto request)
        {
            if (request == null || request.SampleCollectionIds == null || request.SampleCollectionIds.Count == 0)
                return Json(new { success = false, message = "No samples selected for receiving." });
            if (!await MayMoveAsync(request.SampleCollectionIds.Select(x => (long)x)))
                return Json(new { success = false, message = "One or more selected samples are not available to you." });

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

            var items = await sampleTransferApiClient.GetWorksheetDataAsync(ids, OwnSamplesOnly);

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
