using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
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
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class LabReportingController(
        ILabReportingApiClient labReportingApiClient,
        ILabOrderApiClient labOrderApiClient,
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
        IAuditLogService auditLogService,
        EMR.Web.Data.ApplicationDbContext dbContext,
        Microsoft.AspNetCore.Hosting.IWebHostEnvironment env,
        ILabReportingConditionApiClient conditionApiClient,
        ILabReportPdfService reportPdfService,
        ILabReportEmailService labReportEmailService,
        IQueryStringEncryptionService encryptionService) : Controller
    {
        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
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

            // Department Access (User Master): only orders / tests of the user's LAB departments
            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv);

            var statuses = await labReportingApiClient.GetStatusesAsync();

            var departmentOptions = scope.Departments
                .Select(x => new SelectListItem { Value = x.Value, Text = x.Text })
                .ToList();

            var categories = await GetScopedCategoriesAsync(departmentId, scope);
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
                Statuses = statuses,
                DepartmentScopeRestricted = scope.Restricted,
                DepartmentScopeNames = scope.Departments.Select(d => d.Text).ToList()
            };

            return View(viewModel);
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> GetCategoriesForDropdown(int? departmentId)
        {
            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) return Json(Array.Empty<object>());
            var categories = await GetScopedCategoriesAsync(departmentId, scope);
            return Json(categories.Select(c => new { value = c.CategoryId, text = c.CategoryName }));
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> GetSubCategoriesForDropdown(int? categoryId)
        {
            var subCategories = await labOrderApiClient.GetSubCategoriesAsync(categoryId);
            return Json(subCategories.Select(s => new { value = s.SubCategoryId, text = s.SubCategoryName }));
        }

        /// <summary>
        /// Hospital Settings > LAB > "Pathologist approval required" for the current branch. When it is on, a report
        /// is approved only from the Pathologist Dashboard, so this screen neither shows nor accepts an approval.
        /// </summary>
        private async Task<bool> PathologistApprovalRequiredAsync()
        {
            var branchId = CurrentBranchId();
            return await dbContext.HospitalSettings
                .AsNoTracking()
                .Where(s => s.BranchId == branchId)
                .Select(s => (bool?)s.PathologistApprovalRequired)
                .FirstOrDefaultAsync() ?? false;
        }

        /// <summary>
        /// The branch whose samples the Report Entry screen works on. On a partially transferred bill each branch
        /// only sees its own tests: the ones it kept, plus the ones transferred to it and received.
        /// </summary>
        private int CurrentBranchId()
            => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

        /// <summary>
        /// LAB departments the logged-in user may report on: User Master > Department Access (Users.DepartmentIds)
        /// limited to active departments of Type LAB. Super admin is not restricted (Ids = null).
        /// </summary>
        private sealed record LabDepartmentScope(bool Restricted, HashSet<int> Ids, List<SelectListItem> Departments)
        {
            /// <summary>Value for the list procedure: null = unrestricted, "" = no department.</summary>
            public string? Csv => Restricted ? string.Join(",", Ids.OrderBy(i => i)) : null;
            public bool Allows(int? departmentId) => !Restricted || (departmentId.HasValue && Ids.Contains(departmentId.Value));
        }

        private LabDepartmentScope? _labScope;

        private async Task<LabDepartmentScope> GetLabDepartmentScopeAsync()
        {
            if (_labScope != null) return _labScope;

            var labDepartments = (await labOrderApiClient.GetDepartmentsAsync()).ToList();   // active, Type = LAB
            if (User.IsSuperAdmin())
            {
                return _labScope = new LabDepartmentScope(false, labDepartments.Select(d => d.DepartmentId).ToHashSet(),
                    labDepartments.Select(d => new SelectListItem(d.DepartmentName, d.DepartmentId.ToString())).ToList());
            }

            var userId = User.GetUserId();
            var csv = await dbContext.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.DepartmentIds).FirstOrDefaultAsync();
            var granted = (csv ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => int.TryParse(s, out var id) ? id : 0).Where(id => id > 0).ToHashSet();
            var allowed = labDepartments.Where(d => granted.Contains(d.DepartmentId)).ToList();

            return _labScope = new LabDepartmentScope(true, allowed.Select(d => d.DepartmentId).ToHashSet(),
                allowed.Select(d => new SelectListItem(d.DepartmentName, d.DepartmentId.ToString())).ToList());
        }

        /// <summary>Keeps only the tests of the user's departments on a reporting detail (Entry page / JSON).</summary>
        private static void ApplyDepartmentScope(LabReportingOrderDetailDto detail, LabDepartmentScope scope)
        {
            if (!scope.Restricted || detail.Items == null) return;
            detail.Items = detail.Items.Where(i => scope.Allows(i.DepartmentID)).ToList();
        }

        /// <summary>Categories of the chosen department, or of all the user's departments when none is chosen.</summary>
        private async Task<List<CategoryDto>> GetScopedCategoriesAsync(int? departmentId, LabDepartmentScope scope)
        {
            if (!scope.Restricted || departmentId.HasValue)
                return (await labOrderApiClient.GetCategoriesAsync(departmentId)).ToList();

            var list = new List<CategoryDto>();
            foreach (var id in scope.Ids)
                list.AddRange(await labOrderApiClient.GetCategoriesAsync(id));
            return list.GroupBy(c => c.CategoryId).Select(g => g.First()).OrderBy(c => c.CategoryName).ToList();
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> Entry(int labOrderId)
        {
            if (labOrderId <= 0)
                return RedirectToAction(nameof(Index));

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId());
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Reporting order details not found or no eligible collected in-house tests.";
                return RedirectToAction(nameof(Index));
            }

            // Department Access: only the tests of the user's LAB departments are shown / editable
            var scope = await GetLabDepartmentScopeAsync();
            ApplyDepartmentScope(detail, scope);
            if (scope.Restricted && detail.Items.Count == 0)
            {
                TempData["ErrorMessage"] = "This order has no test in your departments (User Master > Department Access).";
                return RedirectToAction(nameof(Index));
            }

            var statuses = await labReportingApiClient.GetStatusesAsync();
            var sampleStatuses = await sampleCollectionApiClient.GetStatusesAsync();
            var companyId = User.GetCompanyId();
            var rejectionReasons = (await rejectionReasonApiClient.GetListAsync(status: true, companyId: companyId)).ToList();

            // B2B partner (Franchise / Company) for the banner; display-only, so a failure must never block the page.
            LabReportClientDto? b2bClient = null;
            try { b2bClient = (await labReportingApiClient.GetPrintMetaAsync(labOrderId))?.Client; }
            catch { /* banner-only */ }

            var viewModel = new LabReportingEntryPageViewModel
            {
                PathologistApprovalRequired = await PathologistApprovalRequiredAsync(),
                B2BClient = b2bClient,
                Detail = detail,
                Statuses = statuses,
                SampleCollectionStatuses = sampleStatuses,
                RejectionReasons = rejectionReasons
            };

            return View(viewModel);
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
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

            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv);

            var encMap = headerResult.Headers.ToDictionary(
                h => h.LabOrderId,
                h => encryptionService.EncryptParameters(new Dictionary<string, string?> { ["labOrderId"] = h.LabOrderId.ToString() }));

            return Json(new
            {
                success = true,
                stats = headerResult.Stats,
                headers = headerResult.Headers,
                encMap
            });
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> GetDetailJson(int labOrderId)
        {
            if (labOrderId <= 0)
                return Json(new { success = false, message = "Valid LabOrderId is required." });

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId());
            if (detail == null)
                return Json(new { success = false, message = "Reporting details not found." });

            var scope = await GetLabDepartmentScopeAsync();
            ApplyDepartmentScope(detail, scope);
            if (scope.Restricted && detail.Items.Count == 0)
                return Json(new { success = false, message = "This order has no test in your departments (User Master > Department Access)." });

            var statuses = await labReportingApiClient.GetStatusesAsync();

            return Json(new
            {
                success = true,
                detail = detail,
                statuses = statuses
            });
        }

        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> SaveEntryJson([FromBody] SaveLabReportingRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            if (request.ReportStatusId <= 0)
                return Json(new { success = false, message = "Invalid ReportStatusId." });

            // With pathologist approval switched on, only the Pathologist Dashboard may approve.
            if (request.ReportStatusId == 5 && await PathologistApprovalRequiredAsync())
                return Json(new
                {
                    success = false,
                    message = "Pathologist approval is required for this branch. Approve the report from the Pathologist Dashboard."
                });

            var enteredEntries = request.Entries?.Where(e => !string.IsNullOrWhiteSpace(e.TestValue)).ToList() ?? new List<LabReportingItemValueDto>();
            if (enteredEntries.Count == 0)
            {
                return Json(new
                {
                    success = false,
                    message = "Please enter at least one test result value before proceeding."
                });
            }

            // Best-effort "before" snapshot so the audit trail can record exactly which tests changed.
            LabReportingOrderDetailDto? detailBeforeSave = null;
            try { detailBeforeSave = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId()); }
            catch { /* audit-only; must never block the save */ }

            // Department Access: results may be saved only for tests of the user's LAB departments.
            // The check needs the order's tests, so a restricted user cannot save when they could not be loaded.
            var saveScope = await GetLabDepartmentScopeAsync();
            if (saveScope.Restricted)
            {
                if (detailBeforeSave?.Items == null)
                    return Json(new { success = false, message = "Could not verify your department access for this order. Please retry." });

                var inScope = detailBeforeSave.Items.Where(i => saveScope.Allows(i.DepartmentID)).Select(i => i.SamplecollectionID).ToHashSet();
                if (enteredEntries.Any(e => !inScope.Contains(e.SamplecollectionID)))
                    return Json(new
                    {
                        success = false,
                        message = "You can save results only for tests of your departments (User Master > Department Access)."
                    });
            }

            // A test that was transferred to another branch and approved there is shown here read-only:
            // this branch must never write to it, whatever the page posted.
            if (detailBeforeSave?.Items != null)
            {
                var foreignIds = detailBeforeSave.Items.Where(i => i.IsReadOnlyForBranch)
                                                       .Select(i => i.SamplecollectionID).ToHashSet();
                if (foreignIds.Count > 0)
                {
                    var blocked = enteredEntries.Where(e => foreignIds.Contains(e.SamplecollectionID)).ToList();
                    if (blocked.Count > 0)
                    {
                        enteredEntries = enteredEntries.Where(e => !foreignIds.Contains(e.SamplecollectionID)).ToList();
                        request.Entries = request.Entries?.Where(e => !foreignIds.Contains(e.SamplecollectionID)).ToList();

                        if (enteredEntries.Count == 0)
                            return Json(new
                            {
                                success = false,
                                message = "These tests were processed at the branch the sample was transferred to and cannot be changed here."
                            });
                    }
                }
            }

            // A result can only be entered for a test that has a Reference Range configured for this patient.
            // Unchanged values that were saved before this rule existed are left alone so existing reports can still be approved.
            if (detailBeforeSave?.Items != null)
            {
                var itemsById = detailBeforeSave.Items.ToDictionary(i => i.SamplecollectionID);
                var missingRange = enteredEntries
                    .Select(e => itemsById.TryGetValue(e.SamplecollectionID, out var it) ? (Entry: e, Item: it) : default)
                    .Where(x => x.Item != null && !x.Item.RefRangeId.HasValue
                                && !string.Equals(x.Entry.TestValue?.Trim(), x.Item.TestValue?.Trim(), StringComparison.Ordinal))
                    .Select(x => x.Item!.TestName)
                    .Distinct()
                    .ToList();

                if (missingRange.Count > 0)
                {
                    return Json(new
                    {
                        success = false,
                        message = "Need to configure Reference Range first for: " + string.Join(", ", missingRange) + ". Result cannot be entered or submitted until then."
                    });
                }
            }

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

            if (success && request.ReportStatusId == 5)
            {
                // Every approval is recorded with the route it came through, so the printed signature can follow it.
                try
                {
                    await labReportingApiClient.RecordEntryApprovalAsync(
                        request.LabOrderId,
                        enteredEntries.Select(e => e.SamplecollectionID),
                        User.GetUserId(),
                        CurrentBranchId());
                }
                catch (HttpRequestException) { /* never block the save */ }

                // The whole bill may be final now: email the patient's report (background, when enabled).
                labReportEmailService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
            }

            if (success)
            {
                try
                {
                    var detail = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId());
                    string actionName = request.ReportStatusId switch
                    {
                        1 => "LAB.ReportDraftSaved",
                        2 => "LAB.ReportEntryCompleted",
                        3 => "LAB.ReportValidated",
                        4 => "LAB.ReportReCollected",
                        5 => "LAB.ReportApproved",
                        _ => "LAB.ReportSaved"
                    };

                    var testChanges = BuildReportTestChanges(detailBeforeSave, detail);
                    var baseDescription = $"Lab test report {statusName} for patient {detail?.PatientName} ({detail?.PatientCode}). Order: {detail?.BillNo}, Token: {detail?.TokenNo}. Entered results for {request.Entries?.Count ?? 0} test parameter(s).";

                    await auditLogService.LogActivityAsync(
                        eventType: "Lab Reporting",
                        actionName: actionName,
                        description: AppendTestSummary(baseDescription, testChanges),
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
                            ResultCount = request.Entries?.Count ?? 0,
                            ChangedTestCount = testChanges.Count,
                            Tests = testChanges
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

        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> UpdateSampleStatusJson([FromBody] UpdateLabSampleStatusRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0 || request.CollectionStatusId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            // Best-effort "before" snapshot: the update clears entered results on re-collect/reject,
            // so this is the only chance to record which tests (and values) were affected.
            LabReportingOrderDetailDto? detailBeforeStatusChange = null;
            try { detailBeforeStatusChange = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId()); }
            catch { /* audit-only; must never block the update */ }

            // Department Access: the sample status may be changed only for tests of the user's LAB departments.
            var statusScope = await GetLabDepartmentScopeAsync();
            if (statusScope.Restricted)
            {
                if (detailBeforeStatusChange?.Items == null)
                    return Json(new { success = false, message = "Could not verify your department access for this order. Please retry." });

                var affected = detailBeforeStatusChange.Items.Where(i =>
                    (request.SampleCollectionId.HasValue && i.SamplecollectionID == request.SampleCollectionId.Value)
                    || (!request.SampleCollectionId.HasValue && request.ProfileId.HasValue && i.ProfileId == request.ProfileId.Value)
                    || (!request.SampleCollectionId.HasValue && !request.ProfileId.HasValue
                        && request.InvestigationId.HasValue && i.InvestigationID == request.InvestigationId.Value)).ToList();
                if (affected.Count == 0 || affected.Any(i => !statusScope.Allows(i.DepartmentID)))
                    return Json(new
                    {
                        success = false,
                        message = "You can change the sample status only for tests of your departments (User Master > Department Access)."
                    });
            }

            // Same rule for the sample status: the branch that only transferred the sample out cannot
            // re-collect or reject a test that the target branch has already produced and approved.
            if (detailBeforeStatusChange?.Items != null)
            {
                var targeted = detailBeforeStatusChange.Items.Where(i =>
                    (request.SampleCollectionId.HasValue && i.SamplecollectionID == request.SampleCollectionId.Value)
                    || (!request.SampleCollectionId.HasValue && request.ProfileId.HasValue && i.ProfileId == request.ProfileId.Value)
                    || (!request.SampleCollectionId.HasValue && !request.ProfileId.HasValue
                        && request.InvestigationId.HasValue && i.InvestigationID == request.InvestigationId.Value)).ToList();

                if (targeted.Count > 0 && targeted.All(i => i.IsReadOnlyForBranch))
                    return Json(new
                    {
                        success = false,
                        message = "This sample was transferred to another branch and processed there. Its status cannot be changed from this branch."
                    });
            }

            bool success = await labReportingApiClient.UpdateSampleStatusAsync(request);
            if (success)
            {
                try
                {
                    string statusDesc = request.CollectionStatusId switch
                    {
                        1 => "Pending",
                        2 => "Collected",
                        3 => "Re-Collect",
                        4 => "Rejected",
                        _ => "Updated"
                    };

                    var affectedTests = BuildSampleStatusTests(detailBeforeStatusChange, request, statusDesc);
                    var statusDescription = $"Sample status changed to {statusDesc} for LabOrderId {request.LabOrderId} (Reason: {request.RejectionReason ?? "N/A"}).";

                    await auditLogService.LogActivityAsync(
                        eventType: "Lab Reporting Sample Status",
                        actionName: "LAB.SampleStatusChanged",
                        description: AppendTestSummary(statusDescription, affectedTests),
                        userId: User.GetUserId(),
                        branchId: User.GetCurrentBranchId(),
                        moduleCode: "LAB",
                        referenceNo: detailBeforeStatusChange?.BillNo,
                        referenceId: request.LabOrderId,
                        patientCode: detailBeforeStatusChange?.PatientCode,
                        metadata: new
                        {
                            BillNo = detailBeforeStatusChange?.BillNo,
                            StatusName = statusDesc,
                            AffectedTestCount = affectedTests.Count,
                            Tests = affectedTests,
                            request.LabOrderId,
                            request.ProfileId,
                            request.InvestigationId,
                            request.SampleCollectionId,
                            request.CollectionStatusId,
                            request.RejectionReasonId,
                            request.RejectionReason
                        });
                }
                catch
                {
                    // Non-blocking
                }
            }

            return Json(new
            {
                success = success,
                message = success ? "Sample status updated successfully." : "Failed to update sample status."
            });
        }

        /// <summary>
        /// Lab Report as a PDF (QuestPDF). Shown inline in the Print modal on the Entry page, or downloaded with download=true.
        /// Prints Validated + Approved tests; a "NOT APPROVED" watermark is applied while any printed test is not yet approved.
        /// Each Department / Test Category starts on a new page.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> PrintReportPdf(int labOrderId, bool download = false, bool conditions = true, string? scope = null)
        {
            if (labOrderId <= 0)
                return BadRequest(new { message = "Valid LabOrderId is required." });

            try
            {
                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var vm = await reportPdfService.BuildAsync(labOrderId, User, scope);
                if (vm == null)
                    return NotFound(new { message = "Lab report details not found." });

                if (vm.IncludedTestCount == 0)
                    return Conflict(new
                    {
                        message = scope switch
                        {
                            LabReportPrintBuilder.ScopeApproved => "Nothing to print yet. Approve at least one test to print the approved report.",
                            LabReportPrintBuilder.ScopePending => "There is no validated (not yet approved) test to print.",
                            _ => "Nothing to print yet. Validate at least one test to print a report."
                        }
                    });

                var pdf = LabReportPdfDocument.Generate(vm, reportPdfService.LoadLogo(vm.HospitalLogoPath), conditions);

                var safeBill = new string((vm.BillNo ?? $"Order{labOrderId}").Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
                var fileName = $"LabReport_{safeBill}{(vm.ShowNotApprovedWatermark ? "_NOT-APPROVED" : "")}.pdf";

                Response.Headers["X-Report-Scope"] = scope;
                Response.Headers.CacheControl = "no-store";
                Response.Headers["X-Report-Status"] = vm.IsFinal ? "final" : "provisional";
                Response.Headers["X-Report-Watermark"] = vm.ShowNotApprovedWatermark ? "1" : "0";
                Response.Headers["X-Report-Tests"] = vm.IncludedTestCount.ToString();
                Response.Headers["Access-Control-Expose-Headers"] = "X-Report-Status, X-Report-Watermark, X-Report-Tests, X-Report-Scope";

                if (download)
                    return File(pdf, "application/pdf", fileName);

                Response.Headers.ContentDisposition = $"inline; filename=\"{fileName}\"";
                return File(pdf, "application/pdf");
            }
            catch (HttpRequestException)
            {
                return StatusCode(503, new { message = "The reporting service is unreachable. Please try again." });
            }
        }

        /// <summary>Records that the report was printed (called by the Print modal when the user clicks Print).</summary>
        [HttpPost]
        public async Task<IActionResult> LogReportPrintedJson(int labOrderId, string? scope = null)
        {
            if (labOrderId <= 0)
                return Json(new { success = false });

            try
            {
                var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
                if (detail == null) return Json(new { success = false });

                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var summary = LabReportPrintBuilder.Summarize(detail, scope);
                var kind = summary.ShowNotApprovedWatermark ? "Provisional copy (NOT APPROVED watermark)"
                         : summary.IsFinal ? "Final report" : "Provisional report";

                await auditLogService.LogActivityAsync(
                    eventType: "Lab Reporting",
                    actionName: "LAB.ReportPrinted",
                    description: $"Lab report printed - {kind}{(scope == LabReportPrintBuilder.ScopePending ? " " + LabReportPdfService.PendingCopyMarker : scope == LabReportPrintBuilder.ScopeApproved ? " (approved tests only)" : "")} - for patient {detail.PatientName} ({detail.PatientCode}). Order: {detail.BillNo}, Token: {detail.TokenNo}. {summary.IncludedTestCount} test(s) on the printout.",
                    userId: User.GetUserId(),
                    branchId: User.GetCurrentBranchId(),
                    moduleCode: "LAB",
                    referenceNo: detail.BillNo,
                    referenceId: detail.LabOrderId,
                    patientCode: detail.PatientCode,
                    metadata: new
                    {
                        detail.LabOrderId,
                        detail.BillNo,
                        Scope = scope,
                        IsFinal = summary.IsFinal,
                        NotApprovedWatermark = summary.ShowNotApprovedWatermark,
                        TestsPrinted = summary.IncludedTestCount,
                        TestsNotPrinted = summary.ExcludedTestCount
                    });

                return Json(new { success = true });
            }
            catch
            {
                // Audit only - never surface an error to the print flow
                return Json(new { success = false });
            }
        }

        /// <summary>Full activity trail (booking, payment, collection, transfer, reporting) for one Lab Order / Bill.</summary>
        [HttpGet]
        public async Task<IActionResult> GetAuditHistoryJson(int labOrderId)
        {
            if (labOrderId <= 0)
                return Json(new { success = false, message = "Valid LabOrderId is required." });

            try
            {
                var rows = await labReportingApiClient.GetActivityHistoryAsync(labOrderId);
                var events = rows.Select(r => new
                {
                    eventDate = r.EventDate,
                    source = r.Source,
                    eventType = r.EventType,
                    actionName = r.ActionName,
                    description = r.Description,
                    userName = string.IsNullOrWhiteSpace(r.UserName) ? "System" : r.UserName,
                    branchName = r.BranchName,
                    ipAddress = r.IpAddress,
                    metadata = ParseMetadata(r.MetadataJson)
                }).ToList();

                return Json(new { success = true, events });
            }
            catch (HttpRequestException)
            {
                return Json(new { success = false, message = "Unable to load audit history right now. The service is unreachable." });
            }
        }

        // ── Audit helpers ────────────────────────────────────────────────────────

        private const int AuditValueMaxLength = 200;

        /// <summary>One test line inside an audit entry's metadata ("Tests" array). Unused members stay null.</summary>
        private sealed record AuditTestEntry
        {
            public long SampleCollectionId { get; init; }
            public int InvestigationId { get; init; }
            public string? TestName { get; init; }
            public string? ProfileName { get; init; }
            public string Change { get; init; } = string.Empty;
            public string? FromStatus { get; init; }
            public string? ToStatus { get; init; }
            public bool? ValueChanged { get; init; }
            public string? OldValue { get; init; }
            public string? NewValue { get; init; }
            public string? OldRemarks { get; init; }
            public string? NewRemarks { get; init; }
            public string? Flag { get; init; }
            public string? ClearedValue { get; init; }
            public string? ClearedReportStatus { get; init; }
            public string? Reason { get; init; }
        }

        private static string ReportStatusLabel(int statusId) => statusId switch
        {
            0 => "Pending Entry",
            1 => "Draft",
            2 => "Submitted",
            3 => "Validated",
            4 => "Re-collected",
            5 => "Approved",
            _ => $"Status {statusId}"
        };

        private static string CollectionStatusLabel(int statusId) => statusId switch
        {
            1 => "Pending",
            2 => "Collected",
            3 => "Re-Collect",
            4 => "Rejected",
            _ => $"Status {statusId}"
        };

        private static string AuditNorm(string? value, int max = AuditValueMaxLength)
        {
            var v = (value ?? string.Empty).Trim();
            return v.Length > max ? v[..max] + "…" : v;
        }

        private static string? AuditProfileName(LabReportingItemDto i) =>
            !string.IsNullOrWhiteSpace(i.ProfilePackageName) ? i.ProfilePackageName
            : !string.IsNullOrWhiteSpace(i.ProfileName) ? i.ProfileName
            : i.PackageName;

        /// <summary>Compares the order before/after a save and lists only the tests whose value, remarks or status changed.</summary>
        private static List<AuditTestEntry> BuildReportTestChanges(LabReportingOrderDetailDto? before, LabReportingOrderDetailDto? after)
        {
            var changes = new List<AuditTestEntry>();
            if (before?.Items == null || after?.Items == null) return changes;

            var beforeBySample = before.Items
                .GroupBy(i => i.SamplecollectionID)
                .ToDictionary(g => g.Key, g => g.First());

            foreach (var a in after.Items)
            {
                if (!beforeBySample.TryGetValue(a.SamplecollectionID, out var b)) continue;

                var oldValue = (b.TestValue ?? string.Empty).Trim();
                var newValue = (a.TestValue ?? string.Empty).Trim();
                var oldRemarks = (b.Remarks ?? string.Empty).Trim();
                var newRemarks = (a.Remarks ?? string.Empty).Trim();
                var oldStatus = oldValue.Length == 0 ? 0 : b.ReportStatusId;
                var newStatus = newValue.Length == 0 ? 0 : a.ReportStatusId;

                var valueChanged = !string.Equals(oldValue, newValue, StringComparison.Ordinal);
                var remarksChanged = !string.Equals(oldRemarks, newRemarks, StringComparison.Ordinal);
                var statusChanged = oldStatus != newStatus;
                if (!valueChanged && !remarksChanged && !statusChanged) continue;

                string change;
                if (newValue.Length == 0 && oldValue.Length > 0) change = "Cleared";
                else if (statusChanged) change = ReportStatusLabel(newStatus);
                else change = "Edited";

                changes.Add(new AuditTestEntry
                {
                    SampleCollectionId = a.SamplecollectionID,
                    InvestigationId = a.InvestigationID,
                    TestName = a.TestName,
                    ProfileName = AuditProfileName(a),
                    Change = change,
                    FromStatus = ReportStatusLabel(oldStatus),
                    ToStatus = ReportStatusLabel(newStatus),
                    ValueChanged = valueChanged,
                    OldValue = AuditNorm(oldValue),
                    NewValue = AuditNorm(newValue),
                    OldRemarks = remarksChanged ? AuditNorm(oldRemarks) : null,
                    NewRemarks = remarksChanged ? AuditNorm(newRemarks) : null,
                    Flag = a.AbnormalFlag
                });
            }

            return changes;
        }

        /// <summary>Lists the tests targeted by a sample status change, with the result/status that existed before it (re-collect/reject clears results).</summary>
        private static List<AuditTestEntry> BuildSampleStatusTests(LabReportingOrderDetailDto? before, UpdateLabSampleStatusRequestDto request, string newStatusLabel)
        {
            var tests = new List<AuditTestEntry>();
            if (before?.Items == null) return tests;

            IEnumerable<LabReportingItemDto> scope;
            if (request.SampleCollectionId.HasValue)
                scope = before.Items.Where(i => i.SamplecollectionID == request.SampleCollectionId.Value);
            else if (request.ProfileId.HasValue)
                scope = before.Items.Where(i => i.ProfileId == request.ProfileId.Value);
            else if (request.InvestigationId.HasValue)
                scope = before.Items.Where(i => i.InvestigationID == request.InvestigationId.Value);
            else
                return tests;

            foreach (var i in scope)
            {
                var hadValue = !string.IsNullOrWhiteSpace(i.TestValue);
                tests.Add(new AuditTestEntry
                {
                    SampleCollectionId = i.SamplecollectionID,
                    InvestigationId = i.InvestigationID,
                    TestName = i.TestName,
                    ProfileName = AuditProfileName(i),
                    Change = newStatusLabel,
                    FromStatus = CollectionStatusLabel(i.CollectionstatusID),
                    ToStatus = newStatusLabel,
                    ClearedValue = hadValue ? AuditNorm(i.TestValue) : null,
                    ClearedReportStatus = hadValue ? ReportStatusLabel(i.ReportStatusId) : null,
                    Reason = AuditNorm(request.RejectionReason)
                });
            }

            return tests;
        }

        /// <summary>Appends "Tests: a, b, c" to a description, keeping it within the AuditLogs.Description limit (2000).</summary>
        private static string AppendTestSummary(string description, List<AuditTestEntry> tests)
        {
            if (tests.Count == 0) return description;

            var names = tests
                .Select(t => t.TestName)
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .ToList();

            var suffix = $" Tests affected ({tests.Count}): {string.Join(", ", names)}.";
            const int limit = 1900;
            if (description.Length + suffix.Length > limit)
                suffix = suffix[..Math.Max(0, limit - description.Length - 1)] + "…";

            return description + suffix;
        }

        private static System.Text.Json.JsonElement? ParseMetadata(string? json)
        {
            if (string.IsNullOrWhiteSpace(json)) return null;
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                return doc.RootElement.Clone();
            }
            catch
            {
                return null;
            }
        }
    }
}
