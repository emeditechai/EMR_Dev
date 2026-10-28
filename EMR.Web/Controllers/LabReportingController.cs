using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
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
        ILabCriticalApiClient labCriticalApiClient,
        ILabOrderApiClient labOrderApiClient,
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
        IAuditLogService auditLogService,
        EMR.Web.Data.ApplicationDbContext dbContext,
        Microsoft.AspNetCore.Hosting.IWebHostEnvironment env,
        ILabReportingConditionApiClient conditionApiClient,
        ILabReportPdfService reportPdfService,
        ILabReportEmailService labReportEmailService,
        ILabReportWhatsAppService labReportWhatsAppService,
        ILabFormulaParameterApiClient labFormulaApiClient,
        IQueryStringEncryptionService encryptionService,
        EMR.Shared.Security.IActionPermissionGuard permissionGuard) : Controller
    {
        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> Index(
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
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
            // Save Draft is no longer part of the flow (entry starts at Submit): the "Draft" bucket now means
            // "some tests further along than others on this bill", shown as In Progress as on Image Reporting.
            LabImageReportingController.RelabelDraftAsInProgress(headerResult);

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
                DateFilterType = dateFilterType ?? "CollectionDate",
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

        /// <summary>
        /// Calculated parameters of this order (Lab Master &gt; Lab Formula Component), keyed by test code.
        /// The hint shows the formula with test names instead of codes where the test is on the order.
        /// </summary>
        private Task<Dictionary<string, LabFormulaTargetInfo>> GetFormulaTargetsAsync(int labOrderId, LabReportingOrderDetailDto detail)
            => LoadFormulaTargetsAsync(labFormulaApiClient, User.GetCompanyId(), labOrderId, detail);

        /// <summary>The order's calculated parameters (Lab Master > Lab Formula Component), by target test code.</summary>
        internal static async Task<Dictionary<string, LabFormulaTargetInfo>> LoadFormulaTargetsAsync(
            ILabFormulaParameterApiClient labFormulaApiClient, int companyId, int labOrderId, LabReportingOrderDetailDto detail)
        {
            var targets = new Dictionary<string, LabFormulaTargetInfo>(StringComparer.OrdinalIgnoreCase);
            try
            {
                var formulas = await labFormulaApiClient.GetForOrderAsync(labOrderId, companyId);
                var names = detail.Items
                    .Where(i => !string.IsNullOrWhiteSpace(i.TestCode))
                    .GroupBy(i => i.TestCode!, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key, g => g.First().TestName, StringComparer.OrdinalIgnoreCase);

                foreach (var f in formulas)
                {
                    var hint = System.Text.RegularExpressions.Regex.Replace(f.FormulaExpression ?? "", @"\[([^\]]+)\]",
                        m => names.TryGetValue(m.Groups[1].Value.Trim(), out var n) ? n : m.Groups[1].Value.Trim());
                    targets[f.TargetTestCode] = new LabFormulaTargetInfo
                    {
                        TestCode = f.TargetTestCode,
                        TestName = f.TargetTestName,
                        Expression = f.FormulaExpression ?? string.Empty,
                        Hint = hint,
                        RoundingPrecision = f.RoundingPrecision,
                        ValidityCondition = f.ValidityCondition
                    };
                }
            }
            catch (HttpRequestException)
            {
                // the page still works: without the configuration nothing is auto-calculated
            }
            return targets;
        }

        /// <summary>
        /// Report Entry calls this while the technician types: every calculated parameter of the order is
        /// worked out on the server from its configured formula, never in the browser.
        /// </summary>
        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> CalculateFormulasJson([FromBody] LabFormulaEvaluateRequestModel request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "A valid lab order is required." });

            try
            {
                request.CompanyId = User.GetCompanyId();
                var results = await labFormulaApiClient.EvaluateAsync(request);
                return Json(new { success = true, results });
            }
            catch (HttpRequestException)
            {
                return Json(new { success = false, message = "The calculation service is not reachable. Please retry." });
            }
        }

        /// <summary>Keeps only the tests of the user's departments on a reporting detail (Entry page / JSON).</summary>
        private static void ApplyDepartmentScope(LabReportingOrderDetailDto detail, LabDepartmentScope scope)
        {
            if (!scope.Restricted || detail.Items == null) return;
            detail.Items = detail.Items.Where(i => scope.Allows(i.DepartmentID)).ToList();
        }

        /// <summary>Keeps only tests whose LabInvestigationMaster Reporting_Type is Numeric on the Numeric Entry page.</summary>
        private static void FilterNumericReportingOnly(LabReportingOrderDetailDto? detail)
        {
            if (detail?.Items == null) return;
            detail.Items = detail.Items
                .Where(i => string.Equals(i.ReportingType?.Trim(), "Numeric", StringComparison.OrdinalIgnoreCase))
                .ToList();
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

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Numeric");
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

            // Lab Report Entry belongs only to Numeric Report tests
            FilterNumericReportingOnly(detail);

            // Microbiology (Reporting Type Template) tests of the bill are reported on Microbiology Report Entry:
            // a bill with only those opens there (links from Un-Authorize, reports ...), a mixed bill links to it.
            var hasTemplateTests = false;
            try
            {
                var template = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), LabReportTypes.Template);
                hasTemplateTests = template?.Items is { Count: > 0 };
            }
            catch (HttpRequestException) { /* the link is a convenience only */ }

            if (detail.Items.Count == 0)
            {
                if (hasTemplateTests)
                    return RedirectToAction("Entry", "MicrobiologyReporting", new { labOrderId });
                TempData["ErrorMessage"] = "This order does not contain any eligible Numeric report tests.";
                return RedirectToAction(nameof(Index));
            }
            if (hasTemplateTests)
                ViewData["RelatedReportLink"] = ("MicrobiologyReporting", "Microbiology Report Entry", "This bill also has microbiology tests");

            var statuses = await labReportingApiClient.GetStatusesAsync();
            var sampleStatuses = await sampleCollectionApiClient.GetStatusesAsync();
            var companyId = User.GetCompanyId();
            var rejectionReasons = (await rejectionReasonApiClient.GetListAsync(status: true, companyId: companyId)).ToList();

            // B2B partner (Franchise / Company) for the banner; display-only, so a failure must never block the page.
            LabReportClientDto? b2bClient = null;
            try { b2bClient = (await labReportingApiClient.GetPrintMetaAsync(labOrderId))?.Client; }
            catch { /* banner-only */ }

            ViewData["FormulaTargets"] = await GetFormulaTargetsAsync(labOrderId, detail);

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
            string? dateFilterType = "CollectionDate",
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
            // Save Draft is no longer part of the flow (entry starts at Submit): the "Draft" bucket now means
            // "some tests further along than others on this bill", shown as In Progress as on Image Reporting.
            LabImageReportingController.RelabelDraftAsInProgress(headerResult);

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

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Numeric");
            if (detail == null)
                return Json(new { success = false, message = "Reporting details not found." });

            var scope = await GetLabDepartmentScopeAsync();
            ApplyDepartmentScope(detail, scope);
            if (scope.Restricted && detail.Items.Count == 0)
                return Json(new { success = false, message = "This order has no test in your departments (User Master > Department Access)." });

            FilterNumericReportingOnly(detail);
            if (detail.Items.Count == 0)
                return Json(new { success = false, message = "This order does not contain any eligible Numeric report tests." });

            var statuses = await labReportingApiClient.GetStatusesAsync();

            return Json(new
            {
                success = true,
                detail = detail,
                statuses = statuses
            });
        }

        // ── Delta check trend (SQLScripts/2295) ─────────────────────────────────────────────────────────────
        /// <summary>The patient's last 5 earlier results of a test (same rule as the row's "Previous" value: other orders,
        /// active entries with a value, newest first) for the trend popup on Lab Report Entry.</summary>
        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> DeltaHistoryJson(int labOrderId, int investigationId)
        {
            if (labOrderId <= 0 || investigationId <= 0) return Json(new { success = false, message = "Invalid request." });
            try
            {
                var con = dbContext.Database.GetDbConnection();
                var rows = await Dapper.SqlMapper.QueryAsync<DeltaHistoryRow>(con, @"
                    DECLARE @PatientId INT = (SELECT PatientId FROM dbo.LabOrder WHERE LabOrderId = @labOrderId);
                    SELECT TOP 5 prev_led.TestValue AS Value, prev_lo.OrderDate, prev_lo.BillNo,
                           COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS Unit,
                           prev_led.ReportStatusId AS StatusId
                      FROM dbo.labentrydetails prev_led
                      JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
                      LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
                      LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
                     WHERE @PatientId IS NOT NULL
                       AND prev_led.PatientId = @PatientId
                       AND prev_led.InvestigationID = @investigationId
                       AND prev_led.LabOrderId <> @labOrderId
                       AND prev_led.IsActive = 1
                       AND prev_led.TestValue IS NOT NULL AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
                     ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC",
                    new { labOrderId, investigationId });
                return Json(new
                {
                    success = true,
                    items = rows.Select(r => new
                    {
                        value = r.Value?.Trim(),
                        date = r.OrderDate?.ToString("dd MMM yyyy"),
                        time = r.OrderDate?.ToString("hh:mm tt"),
                        billNo = r.BillNo,
                        unit = r.Unit,
                        approved = r.StatusId == 5
                    })
                });
            }
            catch (Exception)
            {
                return Json(new { success = false, message = "Previous results could not be loaded." });
            }
        }

        private sealed class DeltaHistoryRow
        {
            public string? Value { get; set; }
            public DateTime? OrderDate { get; set; }
            public string? BillNo { get; set; }
            public string? Unit { get; set; }
            public int? StatusId { get; set; }
        }

        // ── Reflex test suggestions (SQLScripts/2289; AI features switch) ─────────────────────────────────
        /// <summary>Follow-up tests the order's entered results call for, per Master > Lab Master > Reflex Rules.</summary>
        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        [EMR.Shared.Security.RequiresPermission("LAB.LABREPORTING", "REFLEX")]
        public async Task<IActionResult> ReflexSuggestions(int labOrderId,
            [FromServices] EMR.Web.Services.IAiBillingFeatures aiFeatures,
            [FromServices] EMR.Web.Services.Reflex.ILabReflexService reflex)
        {
            if (labOrderId <= 0 || !await aiFeatures.IsEnabledAsync(HttpContext)) return Json(new { success = false, enabled = false });
            try
            {
                return Json(new { success = true, enabled = true, items = await reflex.GetSuggestionsAsync(User.GetCompanyId(), labOrderId) });
            }
            catch (Exception)
            {
                return Json(new { success = false, enabled = true });   // reporting goes on without suggestions
            }
        }

        /// <summary>Advise (A) or dismiss (D) a reflex suggestion. A recommendation only: bill, order and report are unchanged.</summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        [EMR.Web.Filters.LabReportingAccess]
        [EMR.Shared.Security.RequiresPermission("LAB.LABREPORTING", "REFLEX")]
        public async Task<IActionResult> ReflexAction(int labOrderId, int ruleId, string? status, string? note,
            [FromServices] EMR.Web.Services.IAiBillingFeatures aiFeatures,
            [FromServices] EMR.Web.Services.Reflex.ILabReflexService reflex)
        {
            if (labOrderId <= 0 || ruleId <= 0 || status is not ("A" or "D")) return Json(new { success = false, message = "Invalid request." });
            if (!await aiFeatures.IsEnabledAsync(HttpContext)) return Json(new { success = false, message = "AI features are switched off for this branch." });
            var error = await reflex.RecordAsync(User.GetCompanyId(), CurrentBranchId(), User.GetUserId(), labOrderId, ruleId, status[0], note);
            if (error is not null) return Json(new { success = false, message = error });
            await auditLogService.LogAsync("LAB", "LAB.ReflexTest",
                $"Reflex rule #{ruleId} {(status == "A" ? "advised" : "dismissed")} on lab order #{labOrderId}.");
            return Json(new { success = true });
        }

        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> SaveEntryJson([FromBody] SaveLabReportingRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            if (request.ReportStatusId <= 0)
                return Json(new { success = false, message = "Invalid ReportStatusId." });

            // Validating and approving are actions of their own (Settings > Security > this page).
            if (request.ReportStatusId == 3
                && !await permissionGuard.AllowsAsync(HttpContext, "LAB.LABREPORTING", EMR.Shared.Security.PermissionControls.Validate))
                return Json(new { success = false, code = "FORBIDDEN", message = "You do not have permission to validate reports." });
            if (request.ReportStatusId == 5
                && !await permissionGuard.AllowsAsync(HttpContext, "LAB.LABREPORTING", EMR.Shared.Security.PermissionControls.Approve))
                return Json(new { success = false, code = "FORBIDDEN", message = "You do not have permission to approve reports." });

            // With pathologist approval switched on, only the Pathologist Dashboard may approve.
            if (request.ReportStatusId == 5 && await PathologistApprovalRequiredAsync())
                return Json(new
                {
                    success = false,
                    message = "Pathologist approval is required for this branch. Approve the report from the Pathologist Dashboard."
                });

            // LF-05 (SQLScripts/2254): a parameter with a rejected internal QC run (no corrective action yet) cannot be validated / approved
            if (request.ReportStatusId is 3 or 5)
            {
                var iqcBlock = await EMR.Web.Controllers.Quality.IqcGate.BlockAsync(HttpContext, request.LabOrderId,
                    (request.Entries ?? new()).Where(e => !string.IsNullOrWhiteSpace(e.TestValue)).Select(e => e.SamplecollectionID));
                if (iqcBlock != null)
                    return Json(new { success = false, code = "IQC_REJECTED", message = iqcBlock });
            }

            // NABL: a Critical / Panic result needs its communication recorded before it is approved (SQLScripts/2202)
            if (request.ReportStatusId == 5)
            {
                var criticalBlock = await labCriticalApiClient.GetSignoffBlockAsync(CurrentBranchId(), request.LabOrderId,
                    (request.Entries ?? new()).Select(e => e.SamplecollectionID), "ENTRY", User.GetUserId(), User.IsSuperAdmin());
                if (criticalBlock != null)
                    return Json(new { success = false, code = "CRITICAL_COMM_REQUIRED", message = criticalBlock });
            }

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
            try { detailBeforeSave = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), "Numeric"); }
            catch { /* audit-only; must never block the save */ }
            if (detailBeforeSave != null) FilterNumericReportingOnly(detailBeforeSave);

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

                // The whole bill may be final now: email / WhatsApp the patient's report (background, when enabled).
                labReportEmailService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
                labReportWhatsAppService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
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
            try { detailBeforeStatusChange = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), "Numeric"); }
            catch { /* audit-only; must never block the update */ }
            if (detailBeforeStatusChange != null) FilterNumericReportingOnly(detailBeforeStatusChange);

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
        /// reportingType: omitted / "Numeric" = the Lab Report (as always); "Template" = the Microbiology Report;
        /// "auto" (the shared print modal on list pages) = whichever the bill can print, the Lab Report first -
        /// X-Report-Available then names every report of the bill so the modal can offer the other one.
        [HttpGet]
        public async Task<IActionResult> PrintReportPdf(int labOrderId, bool download = false, bool conditions = true, string? scope = null, string? reportingType = null)
        {
            if (labOrderId <= 0)
                return BadRequest(new { message = "Valid LabOrderId is required." });

            try
            {
                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var available = new List<string>();
                string reportType;
                if (string.Equals(reportingType, "auto", StringComparison.OrdinalIgnoreCase))
                {
                    available = await reportPdfService.GetPrintableReportTypesAsync(labOrderId, scope);
                    reportType = available.FirstOrDefault() ?? LabReportTypes.Numeric;
                }
                else
                {
                    reportType = LabReportTypes.Normalize(reportingType);
                }

                var vm = await reportPdfService.BuildAsync(labOrderId, User, scope, reportType);
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
                var fileName = $"{LabReportTypes.FilePrefix(reportType)}_{safeBill}{(vm.ShowNotApprovedWatermark ? "_NOT-APPROVED" : "")}.pdf";

                Response.Headers["X-Report-Scope"] = scope;
                Response.Headers["X-Report-Type"] = reportType;
                Response.Headers["X-Report-Available"] = string.Join(",", available);
                Response.Headers.CacheControl = "no-store";
                Response.Headers["X-Report-Status"] = vm.IsFinal ? "final" : "provisional";
                Response.Headers["X-Report-Watermark"] = vm.ShowNotApprovedWatermark ? "1" : "0";
                Response.Headers["X-Report-Tests"] = vm.IncludedTestCount.ToString();
                Response.Headers["Access-Control-Expose-Headers"] = "X-Report-Status, X-Report-Watermark, X-Report-Tests, X-Report-Scope, X-Report-Type, X-Report-Available";

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
        public async Task<IActionResult> LogReportPrintedJson(int labOrderId, string? scope = null, string? reportingType = null)
        {
            if (labOrderId <= 0)
                return Json(new { success = false });

            var reportType = LabReportTypes.Normalize(reportingType);
            try
            {
                var detail = await labReportingApiClient.GetDetailAsync(labOrderId, null, reportType);
                if (detail == null) return Json(new { success = false });

                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var summary = LabReportPrintBuilder.Summarize(detail, scope);
                var kind = summary.ShowNotApprovedWatermark ? "Provisional copy (NOT APPROVED watermark)"
                         : summary.IsFinal ? "Final report" : "Provisional report";

                await auditLogService.LogActivityAsync(
                    eventType: "Lab Reporting",
                    actionName: "LAB.ReportPrinted",
                    description: $"{LabReportTypes.Title(reportType)} printed{LabReportTypes.Marker(reportType)} - {kind}{(scope == LabReportPrintBuilder.ScopePending ? " " + LabReportPdfService.PendingCopyMarker : scope == LabReportPrintBuilder.ScopeApproved ? " (approved tests only)" : "")} - for patient {detail.PatientName} ({detail.PatientCode}). Order: {detail.BillNo}, Token: {detail.TokenNo}. {summary.IncludedTestCount} test(s) on the printout.",
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
                        ReportType = reportType,
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

        // ── Workflow tracker (Audit History modal, SQLScripts/2297) ────────────────────────────────────────────
        private sealed class WorkflowFacts
        {
            public DateTime OrderDate { get; set; }
            public bool IsB2B { get; set; }
            public bool IsActive { get; set; }
            public string? BookedBy { get; set; }
            public decimal? NetAmount { get; set; }
            public decimal? TotalPaid { get; set; }
            public decimal? BalanceDue { get; set; }
            public DateTime? PaidAt { get; set; }
            public int Total { get; set; }
            public int Collected { get; set; }
            public int ReCollect { get; set; }
            public int Rejected { get; set; }
            public int Outsourced { get; set; }
            public DateTime? LastCollected { get; set; }
            public int Transferred { get; set; }
            public int Received { get; set; }
            public DateTime? LastTransferred { get; set; }
            public DateTime? LastReceived { get; set; }
            public int Entered { get; set; }
            public int Validated { get; set; }
            public int Approved { get; set; }
            public DateTime? LastEntered { get; set; }
            public DateTime? LastValidated { get; set; }
            public DateTime? LastApproved { get; set; }
            public DateTime? EmailedAt { get; set; }
            public DateTime? WhatsAppAt { get; set; }
        }

        /// <summary>
        /// The bill's journey from booking to report delivery for the Audit History modal: every stage with where it
        /// stands (done / in progress / waiting / needs attention), when and by whom - worked out from the order itself,
        /// so a stage shows even when no activity was recorded for it. Read-only.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> GetOrderWorkflowJson(int labOrderId)
        {
            if (labOrderId <= 0) return Json(new { success = false, message = "Valid LabOrderId is required." });
            return Json(await BuildOrderWorkflowAsync(dbContext.Database.GetDbConnection(), labOrderId));
        }

        /// <summary>The bill's workflow (the object GetOrderWorkflowJson returns); also shown to the patient on the
        /// Patient Portal (PatientPortalController.LabWorkflow), without staff names.</summary>
        internal static async Task<object> BuildOrderWorkflowAsync(System.Data.Common.DbConnection con, int labOrderId)
        {
            try
            {
                using var multi = await Dapper.SqlMapper.QueryMultipleAsync(con, @"
                    SELECT lo.OrderDate, CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, CAST(ISNULL(lo.IsActive, 1) AS BIT) AS IsActive,
                           (SELECT COALESCE(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = lo.CreatedBy) AS BookedBy,
                           ph.NetAmount, ph.TotalPaid, ph.BalanceDue, COALESCE(ph.LastModifiedDate, ph.CreatedDate) AS PaidAt,
                           s.Total, s.Collected, s.ReCollect, s.Rejected, s.Outsourced, s.LastCollected,
                           s.Transferred, s.Received, s.LastTransferred, s.LastReceived,
                           e.Entered, e.Validated, e.Approved, e.LastEntered, e.LastValidated, e.LastApproved,
                           (SELECT MAX(SentDate) FROM dbo.LabReportEmailLog m WHERE m.LabOrderId = lo.LabOrderId AND m.SentDate IS NOT NULL) AS EmailedAt,
                           (SELECT MAX(SentDate) FROM dbo.LabReportWhatsAppLog w WHERE w.LabOrderId = lo.LabOrderId AND w.SentDate IS NOT NULL) AS WhatsAppAt
                      FROM dbo.LabOrder lo
                     OUTER APPLY (SELECT TOP 1 h.NetAmount, h.TotalPaid, h.BalanceDue, h.LastModifiedDate, h.CreatedDate
                                    FROM dbo.PaymentHeader h
                                   WHERE h.ModuleCode = 'LAB' AND h.ModuleRefId = lo.LabOrderId AND ISNULL(h.IsActive, 1) = 1
                                   ORDER BY h.PaymentHeaderId DESC) ph
                     OUTER APPLY (SELECT COUNT(*) AS Total,
                                         SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS Collected,
                                         SUM(CASE WHEN sc.CollectionstatusID = 3 THEN 1 ELSE 0 END) AS ReCollect,
                                         SUM(CASE WHEN sc.CollectionstatusID = 4 THEN 1 ELSE 0 END) AS Rejected,
                                         SUM(CASE WHEN ISNULL(sc.IsoutSource, 0) = 1 THEN 1 ELSE 0 END) AS Outsourced,
                                         MAX(CASE WHEN sc.CollectionstatusID = 2 AND sc.Samplecollectiondate IS NOT NULL
                                                  THEN CAST(CAST(sc.Samplecollectiondate AS DATE) AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END) AS LastCollected,
                                         SUM(CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 THEN 1 ELSE 0 END) AS Transferred,
                                         SUM(CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND ISNULL(sc.IsReceived, 0) = 1 THEN 1 ELSE 0 END) AS Received,
                                         MAX(sc.TransferredDate) AS LastTransferred, MAX(sc.ReceivedDate) AS LastReceived
                                    FROM dbo.samplecollection sc
                                   WHERE sc.Laborderid = lo.LabOrderId AND ISNULL(sc.Is_Active, 1) = 1
                                     AND (ISNULL(sc.Iscancelled, 0) = 0 OR ISNULL(lo.IsActive, 1) = 0)) s
                     OUTER APPLY (SELECT SUM(CASE WHEN x.ReportStatusId IN (2, 3, 5) AND x.HasResult = 1 THEN 1 ELSE 0 END) AS Entered,
                                         SUM(CASE WHEN x.ReportStatusId IN (3, 5) THEN 1 ELSE 0 END) AS Validated,
                                         SUM(CASE WHEN x.ReportStatusId = 5 THEN 1 ELSE 0 END) AS Approved,
                                         MAX(x.Submitted_Date) AS LastEntered, MAX(x.Validated_date) AS LastValidated, MAX(x.Approved_Date) AS LastApproved
                                    FROM dbo.samplecollection sc
                                   CROSS APPLY (SELECT TOP 1 l.ReportStatusId, l.Submitted_Date, l.Validated_date, l.Approved_Date,
                                                       CASE WHEN LTRIM(RTRIM(ISNULL(l.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(l.Template_Html, ''))) <> '' THEN 1 ELSE 0 END AS HasResult
                                                  FROM dbo.labentrydetails l
                                                 WHERE l.SamplecollectionID = sc.samplecollectionID AND l.IsActive = 1
                                                 ORDER BY l.LabEntryDetailId DESC) x
                                   WHERE sc.Laborderid = lo.LabOrderId AND ISNULL(sc.Is_Active, 1) = 1
                                     AND (ISNULL(sc.Iscancelled, 0) = 0 OR ISNULL(lo.IsActive, 1) = 0)) e
                     WHERE lo.LabOrderId = @labOrderId;

                    SELECT a.ActionName, a.CreatedDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS UserName, a.Description
                      FROM dbo.AuditLogs a
                      LEFT JOIN dbo.Users u ON u.Id = a.UserId
                     WHERE a.ReferenceId = @labOrderId AND a.ModuleCode = 'LAB'
                       AND a.ActionName IN ('LAB.OrderBooked', 'LAB.B2BOrderBooked', 'LAB.PaymentReceived', 'LAB.SampleCollected',
                                            'LAB.AllSamplesCollected', 'LAB.ProfileSamplesCollected', 'LAB.ReportEntryCompleted',
                                            'LAB.ReportValidated', 'LAB.ReportApproved', 'LAB.ReportPrinted', 'LAB.BillCancelled')
                     ORDER BY a.CreatedDate DESC;

                    -- rework: approvals withdrawn (Re-Test / Re-Collect, with reason)
                    SELECT a.CreatedDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS UserName, a.MetadataJson, a.Description
                      FROM dbo.AuditLogs a
                      LEFT JOIN dbo.Users u ON u.Id = a.UserId
                     WHERE a.ReferenceId = @labOrderId AND a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportUnapproved'
                     ORDER BY a.CreatedDate;

                    -- rework: samples sent for re-collection (3) or rejected (4), one row per action
                    SELECT DATEADD(SECOND, DATEDIFF(SECOND, '2000-01-01', l.ChangedOn), '2000-01-01') AS ChangedOn, l.ToStatusId,
                           MAX(l.RejectionReason) AS Reason, MAX(COALESCE(NULLIF(u.FullName, ''), u.Username)) AS UserName,
                           COUNT(*) AS Tests, MIN(lim.Test_Name) AS FirstTest
                      FROM dbo.LabSampleStatusLog l
                      LEFT JOIN dbo.Users u ON u.Id = l.ChangedBy
                      LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = l.InvestigationId
                     WHERE l.LabOrderId = @labOrderId AND l.ToStatusId IN (3, 4)
                     GROUP BY DATEADD(SECOND, DATEDIFF(SECOND, '2000-01-01', l.ChangedOn), '2000-01-01'), l.ToStatusId, l.ChangedBy
                     ORDER BY 1;

                    -- deliveries after a change: revised reports sent
                    SELECT SentDate, 'emailed' AS Channel FROM dbo.LabReportEmailLog
                     WHERE LabOrderId = @labOrderId AND IsRevised = 1 AND SentDate IS NOT NULL
                    UNION ALL
                    SELECT SentDate, 'sent on WhatsApp' FROM dbo.LabReportWhatsAppLog
                     WHERE LabOrderId = @labOrderId AND IsRevised = 1 AND SentDate IS NOT NULL
                     ORDER BY 1;", new { labOrderId });

                var f = await multi.ReadFirstOrDefaultAsync<WorkflowFacts>();
                if (f is null) return (object)(new { success = false, message = "Order not found." });
                var acts = (await multi.ReadAsync<(string ActionName, DateTime CreatedDate, string? UserName, string? Description)>()).ToList();
                (DateTime? At, string? By) Last(params string[] names)
                {
                    var a = acts.FirstOrDefault(x => names.Contains(x.ActionName));
                    return a.ActionName is null ? (null, null) : (a.CreatedDate, a.UserName);
                }

                // ── rework: re-test / re-collect / rejection / revised report ──
                var unapprovals = (await multi.ReadAsync<(DateTime CreatedDate, string? UserName, string? MetadataJson, string? Description)>())
                    .Select(u =>
                    {
                        string? kind = null, reason = null; int tests = 0;
                        try
                        {
                            using var doc = System.Text.Json.JsonDocument.Parse(string.IsNullOrWhiteSpace(u.MetadataJson) ? "{}" : u.MetadataJson);
                            var root = doc.RootElement;
                            if (root.TryGetProperty("UnapprovedFor", out var k) && k.ValueKind == System.Text.Json.JsonValueKind.String) kind = k.GetString();
                            if (root.TryGetProperty("Reason", out var r) && r.ValueKind == System.Text.Json.JsonValueKind.String) reason = r.GetString();
                            if (root.TryGetProperty("ChangedTestCount", out var c) && c.ValueKind == System.Text.Json.JsonValueKind.Number) tests = c.GetInt32();
                        }
                        catch (System.Text.Json.JsonException) { }
                        kind ??= System.Text.RegularExpressions.Regex.IsMatch(u.Description ?? "", "Re-?Collect", System.Text.RegularExpressions.RegexOptions.IgnoreCase) ? "Re-Collect" : "Re-Test";
                        return (At: u.CreatedDate, By: u.UserName, Kind: kind, Reason: reason, Tests: tests);
                    }).ToList();
                var sampleChanges = (await multi.ReadAsync<(DateTime ChangedOn, int ToStatusId, string? Reason, string? UserName, int Tests, string? FirstTest)>()).ToList();
                var revisedSends = (await multi.ReadAsync<(DateTime SentDate, string Channel)>()).ToList();

                var rework = new List<(DateTime At, string Kind, string Title, string Detail, string? By)>();
                foreach (var u in unapprovals)
                    rework.Add((u.At, u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase) ? "recollect" : "retest",
                        $"Approval withdrawn for {u.Kind}",
                        (u.Tests > 0 ? $"{u.Tests} test(s)" : "") + (string.IsNullOrWhiteSpace(u.Reason) ? "" : (u.Tests > 0 ? " · " : "") + "Reason: " + u.Reason), u.By));
                foreach (var c in sampleChanges)
                {
                    // a re-collection requested by withdrawing approval is already listed above
                    if (c.ToStatusId == 3 && unapprovals.Any(u => u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase) && Math.Abs((u.At - c.ChangedOn).TotalSeconds) <= 10)) continue;
                    var what = c.Tests > 1 ? $"{c.Tests} tests" : c.FirstTest ?? "1 test";
                    rework.Add((c.ChangedOn, c.ToStatusId == 4 ? "rejected" : "recollect",
                        c.ToStatusId == 4 ? "Sample rejected" : "Sample sent for re-collection",
                        what + (string.IsNullOrWhiteSpace(c.Reason) ? "" : " · Reason: " + c.Reason), c.UserName));
                }
                foreach (var c in acts.Where(a => a.ActionName == "LAB.BillCancelled"))
                    rework.Add((c.CreatedDate, "cancelled", "Bill cancelled", CancelReason(c.Description), c.UserName));
                foreach (var g in revisedSends.GroupBy(r => r.SentDate.ToString("yyyyMMddHHmm")))
                    rework.Add((g.Min(r => r.SentDate), "revised", "Revised report " + string.Join(", ", g.Select(r => r.Channel).Distinct()), "", null));
                rework = rework.OrderBy(r => r.At).ToList();
                var lastUnapproval = unapprovals.LastOrDefault();
                var recollections = sampleChanges.Count(c => c.ToStatusId == 3) + unapprovals.Count(u => u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase));

                static string Money(decimal? v) => "₹" + (v ?? 0).ToString("#,##0.00", System.Globalization.CultureInfo.GetCultureInfo("en-IN"));
                var steps = new List<object>();
                void Step(string key, string label, string icon, string state, string detail, DateTime? at = null, string? by = null) =>
                    steps.Add(new { key, label, icon, state, detail, at = at?.ToString("dd MMM yyyy, hh:mm tt"), by });

                // 1. booked
                var booked = Last("LAB.OrderBooked", "LAB.B2BOrderBooked");
                Step("booked", f.IsB2B ? "B2B Order Booked" : "Order Booked", "bi-receipt", "done",
                     f.IsB2B ? "Billed to the partner" : "Bill generated", f.OrderDate, booked.By ?? f.BookedBy);

                // 2. payment
                var paid = Last("LAB.PaymentReceived");
                if (f.IsB2B && (f.TotalPaid ?? 0) <= 0)
                    Step("payment", "Payment", "bi-cash-coin", "done", "On the partner's credit account", f.OrderDate);
                else if (f.NetAmount is null)
                    Step("payment", "Payment", "bi-cash-coin", "pending", "No payment recorded yet");
                else if ((f.BalanceDue ?? 0) <= 0)
                    Step("payment", "Payment", "bi-cash-coin", "done", "Fully paid " + Money(f.TotalPaid), paid.At ?? f.PaidAt, paid.By);
                else if ((f.TotalPaid ?? 0) > 0)
                    Step("payment", "Payment", "bi-cash-coin", "current", $"Paid {Money(f.TotalPaid)} of {Money(f.NetAmount)} · due {Money(f.BalanceDue)}", paid.At ?? f.PaidAt, paid.By);
                else
                    Step("payment", "Payment", "bi-cash-coin", "current", "Payment due " + Money(f.BalanceDue));

                // 3. sample collection
                var coll = Last("LAB.AllSamplesCollected", "LAB.SampleCollected", "LAB.ProfileSamplesCollected");
                var outNote = f.Outsourced > 0 ? $" · {f.Outsourced} outsourced" : "";
                if (f.Total == 0)
                    Step("collection", "Sample Collection", "bi-eyedropper", "pending", "No tests to collect");
                else if (f.Rejected > 0 || f.ReCollect > 0)
                {
                    var lastChange = sampleChanges.LastOrDefault();
                    Step("collection", "Sample Collection", "bi-eyedropper", "issue",
                         $"{f.Collected} of {f.Total} collected · " + string.Join(", ", new[] { f.Rejected > 0 ? $"{f.Rejected} rejected" : null, f.ReCollect > 0 ? $"{f.ReCollect} to re-collect" : null }.Where(x => x != null))
                         + (string.IsNullOrWhiteSpace(lastChange.Reason) ? "" : " · " + lastChange.Reason) + outNote,
                         lastChange.UserName is null && lastChange.Reason is null ? f.LastCollected ?? coll.At : lastChange.ChangedOn, lastChange.UserName ?? coll.By);
                }
                else if (f.Collected >= f.Total)
                    Step("collection", "Sample Collection", "bi-eyedropper", "done",
                         $"All {f.Total} sample(s) collected" + (recollections > 0 ? " (after re-collection)" : "") + outNote, f.LastCollected ?? coll.At, coll.By);
                else
                    Step("collection", "Sample Collection", "bi-eyedropper", f.Collected > 0 ? "current" : "pending",
                         f.Collected > 0 ? $"{f.Collected} of {f.Total} collected{outNote}" : "Awaiting collection", f.LastCollected ?? coll.At, coll.By);

                // 4. transfer to another branch (only when samples were sent)
                if (f.Transferred > 0)
                    Step("transfer", "Sample Transfer", "bi-arrow-left-right", f.Received >= f.Transferred ? "done" : "current",
                         f.Received >= f.Transferred ? $"{f.Transferred} sample(s) sent and received" : $"{f.Received} of {f.Transferred} sample(s) received",
                         f.Received > 0 ? f.LastReceived : f.LastTransferred);

                // 5-7. results: the tests that can be reported (rejected ones cannot)
                var reportable = Math.Max(0, f.Total - f.Rejected);
                string Stage(int count) => reportable == 0 ? "pending" : count >= reportable ? "done" : count > 0 ? "current" : "pending";
                string Of(int count, string verb) => reportable == 0 ? "No reportable tests" : count >= reportable ? $"All {reportable} test(s) {verb}" : count > 0 ? $"{count} of {reportable} test(s) {verb}" : "Not started";
                var ent = Last("LAB.ReportEntryCompleted");
                var val = Last("LAB.ReportValidated");
                var apr = Last("LAB.ReportApproved");
                // withdrawn: the last un-approval is newer than the last approval and the tests are not all approved again
                var lastApprovedAt = new[] { f.LastApproved, apr.At }.Where(d => d.HasValue).DefaultIfEmpty().Max();
                var withdrawn = lastUnapproval.Kind is not null && f.Approved < reportable && (lastApprovedAt is null || lastUnapproval.At >= lastApprovedAt);
                var reworkFor = lastUnapproval.Kind is null ? "" : $" (after {lastUnapproval.Kind})";
                var waitingResample = withdrawn && lastUnapproval.Kind!.Contains("Collect", StringComparison.OrdinalIgnoreCase) && f.ReCollect > 0;

                Step("entry", "Result Entry", "bi-pencil-square", Stage(f.Entered),
                     waitingResample && f.Entered < reportable ? "Waiting for the re-collected sample" : Of(f.Entered, "entered") + (lastUnapproval.Kind is not null && f.Entered >= reportable ? reworkFor : ""),
                     f.LastEntered ?? ent.At, ent.By);
                Step("validation", "Validation", "bi-patch-check", Stage(f.Validated), Of(f.Validated, "validated"), f.LastValidated ?? val.At, val.By);
                if (withdrawn)
                    Step("approval", "Approval", "bi-check2-circle", "issue",
                         $"Approval withdrawn for {lastUnapproval.Kind}" + (string.IsNullOrWhiteSpace(lastUnapproval.Reason) ? "" : " · " + lastUnapproval.Reason)
                         + (f.Approved > 0 ? $" · {f.Approved} of {reportable} approved" : ""),
                         lastUnapproval.At, lastUnapproval.By);
                else
                    Step("approval", "Approval", "bi-check2-circle", Stage(f.Approved),
                         Of(f.Approved, "approved") + (lastUnapproval.Kind is not null && f.Approved >= reportable ? $" - re-approved{reworkFor}" : ""),
                         f.LastApproved ?? apr.At, apr.By);

                // 8. report delivered: printed / emailed / WhatsApp
                var printed = Last("LAB.ReportPrinted");
                var channels = new List<string>();
                if (printed.At is not null) channels.Add("printed");
                if (f.EmailedAt is not null) channels.Add("emailed");
                if (f.WhatsAppAt is not null) channels.Add("sent on WhatsApp");
                var deliveredAt = new[] { printed.At, f.EmailedAt, f.WhatsAppAt }.Where(d => d.HasValue).DefaultIfEmpty().Max();
                var allApproved = reportable > 0 && f.Approved >= reportable;
                var lastRevised = revisedSends.Count > 0 ? revisedSends.Max(r => r.SentDate) : (DateTime?)null;
                if (channels.Count == 0)
                    Step("delivery", "Report Delivered", "bi-send-check", allApproved ? "current" : "pending",
                         allApproved ? "Ready - not printed or sent yet" : "After approval");
                else if (withdrawn)
                    // the patient already has a report that is now being corrected
                    Step("delivery", "Report Delivered", "bi-send-check", "issue",
                         $"Earlier report {string.Join(", ", channels)} on {deliveredAt:dd MMM} - revised report needed after {lastUnapproval.Kind}", deliveredAt, printed.By);
                else if (allApproved && lastApprovedAt is not null && deliveredAt < lastApprovedAt)
                    Step("delivery", "Report Delivered", "bi-send-check", "current",
                         $"Revised report not sent yet (earlier report {string.Join(", ", channels)} on {deliveredAt:dd MMM})", deliveredAt, printed.By);
                else
                    Step("delivery", "Report Delivered", "bi-send-check", allApproved ? "done" : "current",
                         (lastRevised is not null && lastRevised >= (lastApprovedAt ?? DateTime.MinValue) ? "Revised report " : "Report ") + string.Join(", ", channels)
                         + (allApproved ? "" : " (part of the tests)"), deliveredAt, printed.By ?? "sent automatically");

                // a cancelled bill: stages it never reached are stopped, and the cancellation closes the flow
                if (!f.IsActive)
                {
                    for (var i = 0; i < steps.Count; i++)
                    {
                        var st = System.Text.Json.JsonSerializer.SerializeToElement(steps[i]);
                        if (st.GetProperty("state").GetString() == "done") continue;
                        steps[i] = new
                        {
                            key = st.GetProperty("key").GetString(), label = st.GetProperty("label").GetString(), icon = st.GetProperty("icon").GetString(),
                            state = "skipped", detail = "Stopped - bill cancelled", at = (string?)null, by = (string?)null
                        };
                    }
                    var cx = acts.FirstOrDefault(a => a.ActionName == "LAB.BillCancelled");
                    Step("cancelled", "Bill Cancelled", "bi-x-octagon", "issue",
                         cx.ActionName is null ? "The bill was cancelled" : CancelReason(cx.Description) is { Length: > 0 } why ? why : "The bill was cancelled",
                         cx.ActionName is null ? null : cx.CreatedDate, cx.UserName);
                }

                return (object)(new
                {
                    success = true, cancelled = !f.IsActive, steps,
                    rework = rework.Select(r => new { at = r.At.ToString("dd MMM yyyy, hh:mm tt"), kind = r.Kind, title = r.Title, detail = r.Detail, by = r.By })
                });
            }
            catch (Exception)
            {
                return (object)(new { success = false, message = "The workflow could not be loaded." });
            }
        }

        /// <summary>"Cancelled Full LAB Bill (Ref #305) → Cancellation No: CN-.., Amount: ₹850.00, Reason: Fault." → the useful part.</summary>
        private static string CancelReason(string? description)
        {
            if (string.IsNullOrWhiteSpace(description)) return "";
            var full = description.Contains("Full", StringComparison.OrdinalIgnoreCase) ? "Full bill" : "Part of the bill";
            var m = System.Text.RegularExpressions.Regex.Match(description, @"Reason:\s*(.+?)\.?\s*$");
            var no = System.Text.RegularExpressions.Regex.Match(description, @"Cancellation No:\s*([^,]+)");
            return full + (no.Success ? " · " + no.Groups[1].Value.Trim() : "") + (m.Success ? " · Reason: " + m.Groups[1].Value.Trim() : "");
        }

        // ── Audit helpers ────────────────────────────────────────────────────────

        private const int AuditValueMaxLength = 200;

        /// <summary>One test line inside an audit entry's metadata ("Tests" array). Unused members stay null.</summary>
        internal sealed record AuditTestEntry
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
        internal static List<AuditTestEntry> BuildReportTestChanges(LabReportingOrderDetailDto? before, LabReportingOrderDetailDto? after)
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
        internal static List<AuditTestEntry> BuildSampleStatusTests(LabReportingOrderDetailDto? before, UpdateLabSampleStatusRequestDto request, string newStatusLabel)
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
        internal static string AppendTestSummary(string description, List<AuditTestEntry> tests)
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
