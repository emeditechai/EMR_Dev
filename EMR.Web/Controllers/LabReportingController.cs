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
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
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
            var sampleStatuses = await sampleCollectionApiClient.GetStatusesAsync();
            var companyId = User.GetCompanyId();
            var rejectionReasons = (await rejectionReasonApiClient.GetListAsync(status: true, companyId: companyId)).ToList();

            var viewModel = new LabReportingEntryPageViewModel
            {
                Detail = detail,
                Statuses = statuses,
                SampleCollectionStatuses = sampleStatuses,
                RejectionReasons = rejectionReasons
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
            try { detailBeforeSave = await labReportingApiClient.GetDetailAsync(request.LabOrderId); }
            catch { /* audit-only; must never block the save */ }

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
        public async Task<IActionResult> UpdateSampleStatusJson([FromBody] UpdateLabSampleStatusRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0 || request.CollectionStatusId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            // Best-effort "before" snapshot: the update clears entered results on re-collect/reject,
            // so this is the only chance to record which tests (and values) were affected.
            LabReportingOrderDetailDto? detailBeforeStatusChange = null;
            try { detailBeforeStatusChange = await labReportingApiClient.GetDetailAsync(request.LabOrderId); }
            catch { /* audit-only; must never block the update */ }

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
