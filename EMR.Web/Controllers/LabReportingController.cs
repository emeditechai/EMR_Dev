using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;

using System.Linq;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class LabReportingController(
        ILabReportingApiClient labReportingApiClient,
        ILabOrderApiClient labOrderApiClient,
        IAuditLogService auditLogService) : Controller
    {
        [HttpGet]
        public async Task<IActionResult> Index(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId);

            var statuses = await labReportingApiClient.GetStatusesAsync();

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

            var viewModel = new LabReportingDashboardViewModel
            {
                BranchId = branchId,
                FromDate = effectiveFrom,
                ToDate = effectiveTo,
                DateFilterType = dateFilterType ?? "BookingDate",
                StatusFilter = statusFilter ?? "All",
                Search = search,
                DepartmentId = departmentId,
                CategoryId = categoryId,
                SubCategoryId = subCategoryId,
                DepartmentOptions = departmentOptions,
                CategoryOptions = categoryOptions,
                SubCategoryOptions = subCategoryOptions,
                Stats = headerResult.Stats,
                Headers = headerResult.Headers,
                Statuses = statuses
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
        public async Task<IActionResult> Entry(int labOrderId)
        {
            if (labOrderId <= 0)
                return RedirectToAction(nameof(Index));

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Reporting order details not found or no eligible collected in-house tests.";
                return RedirectToAction(nameof(Index));
            }

            var statuses = await labReportingApiClient.GetStatusesAsync();

            var viewModel = new LabReportingEntryPageViewModel
            {
                Detail = detail,
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
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId);

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
                return Json(new { success = false, message = "Valid LabOrderId is required." });

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
            if (detail == null)
                return Json(new { success = false, message = "Reporting details not found." });

            var statuses = await labReportingApiClient.GetStatusesAsync();

            return Json(new
            {
                success = true,
                detail = detail,
                statuses = statuses
            });
        }

        [HttpPost]
        public async Task<IActionResult> SaveEntryJson([FromBody] SaveLabReportingRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            if (request.ReportStatusId <= 0)
                return Json(new { success = false, message = "Invalid ReportStatusId." });

            bool success = await labReportingApiClient.SaveEntryAsync(request);
            string statusName = request.ReportStatusId switch
            {
                1 => "saved as Draft",
                2 => "saved and submitted",
                3 => "validated",
                4 => "marked for re-collection",
                5 => "approved",
                _ => "saved"
            };

            if (success)
            {
                try
                {
                    var detail = await labReportingApiClient.GetDetailAsync(request.LabOrderId);
                    string actionName = request.ReportStatusId switch
                    {
                        1 => "LAB.ReportDraftSaved",
                        2 => "LAB.ReportEntryCompleted",
                        3 => "LAB.ReportValidated",
                        4 => "LAB.ReportReCollected",
                        _ => "LAB.ReportSaved"
                    };

                    await auditLogService.LogActivityAsync(
                        eventType: "Lab Reporting",
                        actionName: actionName,
                        description: $"Lab test report {statusName} for patient {detail?.PatientName} ({detail?.PatientCode}). Order: {detail?.BillNo}, Token: {detail?.TokenNo}. Entered results for {request.Entries?.Count ?? 0} test parameter(s).",
                        userId: User.GetUserId(),
                        branchId: User.GetCurrentBranchId(),
                        moduleCode: "LAB",
                        referenceNo: detail?.BillNo,
                        referenceId: request.LabOrderId,
                        patientCode: detail?.PatientCode,
                        metadata: new {
                            request.LabOrderId,
                            detail?.BillNo,
                            detail?.TokenNo,
                            request.ReportStatusId,
                            statusName,
                            ResultCount = request.Entries?.Count ?? 0
                        });
                }
                catch
                {
                    // Non-blocking logging
                }
            }

            return Json(new
            {
                success = success,
                message = success ? $"Report results {statusName}." : "Failed to save report entries."
            });
        }
    }
}
