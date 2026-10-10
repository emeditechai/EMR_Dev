using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;

namespace EMR.Web.Controllers
{
    /// <summary>
    /// LAB > Microbiology Report Entry: the reporting worklist for investigations with Reporting Type 'Template'.
    /// Same list, filters, cards, department scope and access rule as Image Report Entry (LabImageReporting); only the
    /// reporting type differs. A profile whose own investigation is 'Template' (e.g. Urine Routine &amp; Microscopy) is
    /// reported here as a whole - see dbo.ufn_Lab_ReportingTypeKey (SQL 2179).
    /// Report entry uses the Lab Report Entry page and its workflow (Submit > Validate > Approve > Print, sample
    /// re-collect / reject, audit trail); each parameter is entered by its own Reporting Type: Numeric as on Lab Report
    /// Entry, Select from the Lab Parameter Option Master, any other type as a narrative from its descriptive template.
    /// </summary>
    [Authorize]
    public class MicrobiologyReportingController(
        ILabReportingApiClient labReportingApiClient,
        ILabCriticalApiClient labCriticalApiClient,
        ILabOrderApiClient labOrderApiClient,
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
        ILabParameterOptionApiClient parameterOptionApiClient,
        ILabDescriptiveTestTemplateApiClient templateApiClient,
        ILabFormulaParameterApiClient labFormulaApiClient,
        IAuditLogService auditLogService,
        ILabReportPdfService reportPdfService,
        ILabReportEmailService labReportEmailService,
        ILabReportWhatsAppService labReportWhatsAppService,
        EMR.Shared.Security.IActionPermissionGuard permissionGuard,
        EMR.Web.Data.ApplicationDbContext dbContext) : Controller
    {
        private const string PageCode = "LAB.MICROBIOLOGYREPORTING";
        internal const string ReportingType = "Template";

        private int CurrentBranchId()
            => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

        private sealed record LabDepartmentScope(bool Restricted, HashSet<int> Ids, List<SelectListItem> Departments)
        {
            public string? Csv => Restricted ? string.Join(",", Ids.OrderBy(i => i)) : null;
            public bool Allows(int? departmentId) => !Restricted || (departmentId.HasValue && Ids.Contains(departmentId.Value));
        }

        private LabDepartmentScope? _labScope;

        /// <summary>Super admin sees every lab department; anyone else only the departments in User Master > Department Access.</summary>
        private async Task<LabDepartmentScope> GetLabDepartmentScopeAsync()
        {
            if (_labScope != null) return _labScope;

            var labDepartments = (await labOrderApiClient.GetDepartmentsAsync()).ToList();
            if (User.IsSuperAdmin())
            {
                var allOptions = labDepartments
                    .Select(d => new SelectListItem { Value = d.DepartmentId.ToString(), Text = d.DepartmentName })
                    .OrderBy(x => x.Text)
                    .ToList();
                _labScope = new LabDepartmentScope(false, new HashSet<int>(), allOptions);
                return _labScope;
            }

            var userId = User.GetUserId();
            var userDeptCsv = await dbContext.Users
                .AsNoTracking()
                .Where(u => u.Id == userId)
                .Select(u => u.DepartmentIds)
                .FirstOrDefaultAsync();

            var allowedUserIds = (userDeptCsv ?? string.Empty)
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => int.TryParse(s, out var id) ? (int?)id : null)
                .Where(id => id.HasValue)
                .Select(id => id!.Value)
                .ToHashSet();

            var scopedDepts = labDepartments
                .Where(d => allowedUserIds.Contains(d.DepartmentId))
                .Select(d => new SelectListItem { Value = d.DepartmentId.ToString(), Text = d.DepartmentName })
                .OrderBy(x => x.Text)
                .ToList();

            _labScope = new LabDepartmentScope(true, scopedDepts.Select(x => int.Parse(x.Value)).ToHashSet(), scopedDepts);
            return _labScope;
        }

        private async Task<List<CategoryDto>> GetScopedCategoriesAsync(int? departmentId, LabDepartmentScope scope)
        {
            if (!scope.Restricted || departmentId.HasValue)
                return (await labOrderApiClient.GetCategoriesAsync(departmentId)).ToList();

            var list = new List<CategoryDto>();
            foreach (var id in scope.Ids)
                list.AddRange(await labOrderApiClient.GetCategoriesAsync(id));
            return list.GroupBy(c => c.CategoryId).Select(g => g.First()).OrderBy(c => c.CategoryName).ToList();
        }

        private static (DateTime From, DateTime To) EffectiveRange(DateTime? fromDate, DateTime? toDate)
        {
            var today = DateTime.Today;
            var from = fromDate ?? today;
            var to = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);
            return (from, to);
        }

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
            int branchId = CurrentBranchId();
            var (effectiveFrom, effectiveTo) = EffectiveRange(fromDate, toDate);

            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv, reportingType: ReportingType);
            LabImageReportingController.RelabelDraftAsInProgress(headerResult);

            var statuses = await labReportingApiClient.GetStatusesAsync();

            var categories = await GetScopedCategoriesAsync(departmentId, scope);
            var subCategories = await labOrderApiClient.GetSubCategoriesAsync(categoryId);

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
                DepartmentOptions = scope.Departments.Select(x => new SelectListItem { Value = x.Value, Text = x.Text }).ToList(),
                CategoryOptions = categories.Select(x => new SelectListItem { Value = x.CategoryId.ToString(), Text = x.CategoryName }).ToList(),
                SubCategoryOptions = subCategories.Select(x => new SelectListItem { Value = x.SubCategoryId.ToString(), Text = x.SubCategoryName }).ToList(),
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
            int branchId = CurrentBranchId();
            var (effectiveFrom, effectiveTo) = EffectiveRange(fromDate, toDate);

            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv, reportingType: ReportingType);
            LabImageReportingController.RelabelDraftAsInProgress(headerResult);

            return Json(new
            {
                success = true,
                stats = headerResult.Stats,
                headers = headerResult.Headers
            });
        }


        // ── Report entry ─────────────────────────────────────────────────────────

        private async Task<bool> PathologistApprovalRequiredAsync()
        {
            var branchId = CurrentBranchId();
            return await dbContext.HospitalSettings
                .AsNoTracking()
                .Where(s => s.BranchId == branchId)
                .Select(s => (bool?)s.PathologistApprovalRequired)
                .FirstOrDefaultAsync() ?? false;
        }

        private static bool IsType(LabReportingItemDto i, string type) =>
            string.Equals(i.ReportingType?.Trim(), type, StringComparison.OrdinalIgnoreCase);

        /// <summary>Anything that is neither a number nor a picklist answer is written as a narrative.</summary>
        internal static bool IsNarrative(LabReportingItemDto i) => !IsType(i, "Numeric") && !IsType(i, "Select");

        /// <summary>The Template rows of the order this user may work on (department access).</summary>
        private async Task<LabReportingOrderDetailDto?> LoadScopedDetailAsync(int labOrderId)
        {
            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), ReportingType);
            if (detail == null) return null;
            var scope = await GetLabDepartmentScopeAsync();
            detail.Items = (detail.Items ?? new()).Where(i => scope.Allows(i.DepartmentID)).ToList();
            return detail;
        }

        /// <summary>Active picklist answers of the order's Select parameters, by Test_ID, in display order.</summary>
        private async Task<Dictionary<int, List<LabPicklistOption>>> LoadPicklistOptionsAsync(IEnumerable<LabReportingItemDto> items)
        {
            var testIds = items.Where(i => IsType(i, "Select")).Select(i => i.InvestigationID).ToHashSet();
            if (testIds.Count == 0) return new();

            var all = await parameterOptionApiClient.GetListAsync(status: true, companyId: User.GetCompanyId());
            return all.Where(o => testIds.Contains(o.Test_ID))
                      .GroupBy(o => o.Test_ID)
                      .ToDictionary(g => g.Key, g => g.OrderBy(o => o.Display_Order).ThenBy(o => o.Option_Text)
                                                     .Select(o => new LabPicklistOption(o.Option_Text, o.Is_Abnormal, o.Is_Default))
                                                     .ToList());
        }

        /// <summary>
        /// The starting narrative of each descriptive parameter not reported yet: its Lab Descriptive Test Template sections,
        /// with the patient placeholders filled in. Without a template the editor starts empty.
        /// </summary>
        private async Task<Dictionary<long, string>> LoadDescriptiveDefaultsAsync(LabReportingOrderDetailDto detail)
        {
            var defaults = new Dictionary<long, string>();
            var replacements = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["{{PatientName}}"] = detail.PatientName ?? "",
                ["{{PatientAge}}"] = detail.Age.HasValue ? $"{detail.Age} Y" : "",
                ["{{PatientGender}}"] = detail.Gender ?? "",
                ["{{UHID}}"] = detail.PatientCode ?? "",
                ["{{PatientCode}}"] = detail.PatientCode ?? "",
                ["{{ReferringDoctor}}"] = string.IsNullOrWhiteSpace(detail.ReferralDoctorName) ? "Self" : detail.ReferralDoctorName!,
                ["{{ClinicalIndication}}"] = "clinical evaluation",
                ["{{StudyDate}}"] = (detail.BookingDateTime ?? detail.OrderDate).ToString("dd-MMM-yyyy")
            };

            foreach (var group in detail.Items.Where(IsNarrative).GroupBy(i => i.InvestigationID))
            {
                List<LabDescriptiveTestTemplateModel> sections;
                try { sections = (await templateApiClient.GetByTestIdAsync(group.Key)).Where(t => t.IsActive).OrderBy(t => t.Section_Sequence).ToList(); }
                catch (HttpRequestException) { sections = new(); }

                var html = new System.Text.StringBuilder();
                foreach (var sec in sections)
                {
                    var content = sec.Default_Content_Html ?? "<p><br></p>";
                    foreach (var (tag, val) in replacements)
                        content = content.Replace(tag, System.Net.WebUtility.HtmlEncode(val), StringComparison.OrdinalIgnoreCase);
                    html.Append($"<p><strong>{System.Net.WebUtility.HtmlEncode(sec.Section_Name.ToUpperInvariant())}:</strong></p>");
                    html.Append(content);
                }

                foreach (var item in group)
                    defaults[item.SamplecollectionID] = html.ToString();
            }
            return defaults;
        }

        [HttpGet]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> Entry(int labOrderId)
        {
            if (labOrderId <= 0)
                return RedirectToAction(nameof(Index));

            var detail = await LoadScopedDetailAsync(labOrderId);
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Reporting order details not found or no eligible collected in-house tests.";
                return RedirectToAction(nameof(Index));
            }
            if (detail.Items.Count == 0)
            {
                TempData["ErrorMessage"] = (await GetLabDepartmentScopeAsync()).Restricted
                    ? "This order has no Microbiology (Template) investigation in your departments (User Master > Department Access)."
                    : "This order does not contain any eligible Microbiology (Template) investigations.";
                return RedirectToAction(nameof(Index));
            }

            // A bill with Numeric tests as well: link to Lab Report Entry, where those are reported.
            try
            {
                var numeric = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Numeric");
                if (numeric?.Items?.Any(i => string.Equals(i.ReportingType?.Trim(), "Numeric", StringComparison.OrdinalIgnoreCase)) == true)
                    ViewData["RelatedReportLink"] = ("LabReporting", "Lab Report Entry", "This bill also has lab (numeric) tests");
            }
            catch (HttpRequestException) { /* the link is a convenience only */ }

            var statuses = await labReportingApiClient.GetStatusesAsync();
            var sampleStatuses = await sampleCollectionApiClient.GetStatusesAsync();
            var rejectionReasons = (await rejectionReasonApiClient.GetListAsync(status: true, companyId: User.GetCompanyId())).ToList();

            LabReportClientDto? b2bClient = null;
            try { b2bClient = (await labReportingApiClient.GetPrintMetaAsync(labOrderId))?.Client; }
            catch { /* banner-only */ }

            ViewData["FormulaTargets"] = await LabReportingController.LoadFormulaTargetsAsync(labFormulaApiClient, User.GetCompanyId(), labOrderId, detail);

            var viewModel = new LabReportingEntryPageViewModel
            {
                Screen = LabReportingScreen.Microbiology,
                PathologistApprovalRequired = await PathologistApprovalRequiredAsync(),
                B2BClient = b2bClient,
                Detail = detail,
                Statuses = statuses,
                SampleCollectionStatuses = sampleStatuses,
                RejectionReasons = rejectionReasons,
                PicklistOptions = await LoadPicklistOptionsAsync(detail.Items),
                DescriptiveDefaults = await LoadDescriptiveDefaultsAsync(detail)
            };

            return View("~/Views/LabReporting/Entry.cshtml", viewModel);
        }

        /// <summary>Calculated parameters (Lab Master > Lab Formula Component), worked out on the server as on Lab Report Entry.</summary>
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

        /// <summary>
        /// Submit / Validate / Approve, as on Lab Report Entry. The server decides, per parameter, what is stored:
        /// the Reporting Type comes from the master (never the page); a Select answer must be one of the parameter's active
        /// options and its flag is that option's Is_Abnormal; a Numeric value needs a Reference Range; a narrative is kept
        /// in Template_Html.
        /// </summary>
        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> SaveEntryJson([FromBody] SaveLabReportingRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });
            if (request.ReportStatusId <= 0)
                return Json(new { success = false, message = "Invalid ReportStatusId." });

            if (request.ReportStatusId == 3
                && !await permissionGuard.AllowsAsync(HttpContext, PageCode, EMR.Shared.Security.PermissionControls.Validate))
                return Json(new { success = false, code = "FORBIDDEN", message = "You do not have permission to validate reports." });
            if (request.ReportStatusId == 5
                && !await permissionGuard.AllowsAsync(HttpContext, PageCode, EMR.Shared.Security.PermissionControls.Approve))
                return Json(new { success = false, code = "FORBIDDEN", message = "You do not have permission to approve reports." });

            if (request.ReportStatusId == 5 && await PathologistApprovalRequiredAsync())
                return Json(new { success = false, message = "Pathologist approval is required for this branch. Approve the report from the Pathologist Dashboard." });

            // NABL: a Critical / Panic result needs its communication recorded before it is approved (SQLScripts/2202)
            if (request.ReportStatusId == 5)
            {
                var criticalBlock = await labCriticalApiClient.GetSignoffBlockAsync(CurrentBranchId(), request.LabOrderId,
                    (request.Entries ?? new()).Select(e => e.SamplecollectionID), "ENTRY", User.GetUserId(), User.IsSuperAdmin());
                if (criticalBlock != null)
                    return Json(new { success = false, code = "CRITICAL_COMM_REQUIRED", message = criticalBlock });
            }

            request.Entries ??= new();
            if (!request.Entries.Any(e => !string.IsNullOrWhiteSpace(e.TestValue)))
                return Json(new { success = false, message = "Please enter at least one test result value before proceeding." });

            // The order's Template rows this user may work on: every posted row must be one of them.
            LabReportingOrderDetailDto? detailBeforeSave;
            try { detailBeforeSave = await LoadScopedDetailAsync(request.LabOrderId); }
            catch (HttpRequestException) { return Json(new { success = false, message = "The reporting service is not reachable. Please retry." }); }
            if (detailBeforeSave == null)
                return Json(new { success = false, message = "Reporting order details not found." });

            var itemsById = detailBeforeSave.Items.GroupBy(i => i.SamplecollectionID).ToDictionary(g => g.Key, g => g.First());
            if (request.Entries.Any(e => !itemsById.ContainsKey(e.SamplecollectionID)))
                return Json(new { success = false, message = "You can save results only for this order's Microbiology tests of your departments (User Master > Department Access)." });

            // Transferred out and approved at the target branch: read-only here.
            request.Entries = request.Entries.Where(e => !itemsById[e.SamplecollectionID].IsReadOnlyForBranch).ToList();
            var enteredEntries = request.Entries.Where(e => !string.IsNullOrWhiteSpace(e.TestValue)).ToList();
            if (enteredEntries.Count == 0)
                return Json(new { success = false, message = "These tests were processed at the branch the sample was transferred to and cannot be changed here." });

            var options = await LoadPicklistOptionsAsync(detailBeforeSave.Items);
            var missingRange = new List<string>();
            var invalidPick = new List<string>();
            var emptyNarrative = new List<string>();

            foreach (var e in request.Entries)
            {
                var item = itemsById[e.SamplecollectionID];
                e.InvestigationID = item.InvestigationID;
                e.ReportingType = string.IsNullOrWhiteSpace(item.ReportingType) ? "Numeric" : item.ReportingType.Trim();
                var value = e.TestValue?.Trim() ?? string.Empty;
                if (value.Length == 0) continue;
                var unchanged = string.Equals(value, item.TestValue?.Trim(), StringComparison.Ordinal);

                if (IsType(item, "Select"))
                {
                    var match = options.TryGetValue(item.InvestigationID, out var list)
                        ? list.FirstOrDefault(o => string.Equals(o.Text.Trim(), value, StringComparison.OrdinalIgnoreCase))
                        : null;
                    if (match == null)
                    {
                        // a value saved before an option was renamed / retired stays as it is
                        if (!unchanged) { invalidPick.Add(item.TestName); continue; }
                        e.AbnormalFlag = item.AbnormalFlag;
                    }
                    else
                    {
                        e.TestValue = match.Text;
                        e.AbnormalFlag = match.IsAbnormal ? "Abnormal" : "Normal";
                    }
                    e.TemplateHtml = null;
                }
                else if (IsType(item, "Numeric"))
                {
                    if (!item.RefRangeId.HasValue && !unchanged) missingRange.Add(item.TestName);
                    e.TemplateHtml = null;
                }
                else
                {
                    // narrative: the text lives in Template_Html; TestValue only marks the row as reported
                    var text = string.IsNullOrWhiteSpace(e.TemplateHtml) ? string.Empty : LabReportPrintBuilder.HtmlToText(e.TemplateHtml);
                    if (text.Length == 0 && string.IsNullOrWhiteSpace(item.TemplateHtml)) { emptyNarrative.Add(item.TestName); continue; }
                    e.TestValue = "Report Entered";
                    e.AbnormalFlag = null;
                }
            }

            if (missingRange.Count > 0)
                return Json(new { success = false, message = "Need to configure Reference Range first for: " + string.Join(", ", missingRange.Distinct()) + ". Result cannot be entered or submitted until then." });
            if (invalidPick.Count > 0)
                return Json(new { success = false, message = "Choose a value from the list (Lab Parameter Option Master) for: " + string.Join(", ", invalidPick.Distinct()) + "." });
            if (emptyNarrative.Count > 0)
                return Json(new { success = false, message = "Write the report text for: " + string.Join(", ", emptyNarrative.Distinct()) + "." });

            enteredEntries = request.Entries.Where(e => !string.IsNullOrWhiteSpace(e.TestValue)).ToList();

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
                try
                {
                    await labReportingApiClient.RecordEntryApprovalAsync(
                        request.LabOrderId, enteredEntries.Select(e => e.SamplecollectionID), User.GetUserId(), CurrentBranchId());
                }
                catch (HttpRequestException) { /* never block the save */ }

                labReportEmailService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
                labReportWhatsAppService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
            }

            if (success)
            {
                try
                {
                    var detail = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), ReportingType);
                    string actionName = request.ReportStatusId switch
                    {
                        1 => "LAB.ReportDraftSaved",
                        2 => "LAB.ReportEntryCompleted",
                        3 => "LAB.ReportValidated",
                        4 => "LAB.ReportReCollected",
                        5 => "LAB.ReportApproved",
                        _ => "LAB.ReportSaved"
                    };

                    var testChanges = LabReportingController.BuildReportTestChanges(detailBeforeSave, detail);
                    var baseDescription = $"Microbiology report {statusName} for patient {detail?.PatientName} ({detail?.PatientCode}). Order: {detail?.BillNo}, Token: {detail?.TokenNo}. Entered results for {request.Entries.Count} test parameter(s).";

                    await auditLogService.LogActivityAsync(
                        eventType: "Lab Reporting",
                        actionName: actionName,
                        description: LabReportingController.AppendTestSummary(baseDescription, testChanges),
                        userId: User.GetUserId(),
                        branchId: User.GetCurrentBranchId(),
                        moduleCode: "LAB",
                        referenceNo: detail?.BillNo,
                        referenceId: request.LabOrderId,
                        patientCode: detail?.PatientCode,
                        metadata: new
                        {
                            request.LabOrderId,
                            detail?.BillNo,
                            detail?.TokenNo,
                            request.ReportStatusId,
                            statusName,
                            Screen = "Microbiology Report Entry",
                            ResultCount = request.Entries.Count,
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
                success,
                message = success ? $"Report results {statusName}." : "Failed to save report entries."
            });
        }

        /// <summary>Sample Collected / Re-Collect / Rejected for a profile or test of the order, as on Lab Report Entry.</summary>
        [HttpPost]
        [EMR.Web.Filters.LabReportingAccess]
        public async Task<IActionResult> UpdateSampleStatusJson([FromBody] UpdateLabSampleStatusRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0 || request.CollectionStatusId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            var before = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), ReportingType);
            if (before?.Items == null)
                return Json(new { success = false, message = "Could not load this order. Please retry." });

            var targeted = before.Items.Where(i =>
                (request.SampleCollectionId.HasValue && i.SamplecollectionID == request.SampleCollectionId.Value)
                || (!request.SampleCollectionId.HasValue && request.ProfileId.HasValue && i.ProfileId == request.ProfileId.Value)
                || (!request.SampleCollectionId.HasValue && !request.ProfileId.HasValue
                    && request.InvestigationId.HasValue && i.InvestigationID == request.InvestigationId.Value)).ToList();

            var scope = await GetLabDepartmentScopeAsync();
            if (targeted.Count == 0 || targeted.Any(i => !scope.Allows(i.DepartmentID)))
                return Json(new { success = false, message = "You can change the sample status only for tests of your departments (User Master > Department Access)." });
            if (targeted.All(i => i.IsReadOnlyForBranch))
                return Json(new { success = false, message = "This sample was transferred to another branch and processed there. Its status cannot be changed from this branch." });

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
                    var affected = LabReportingController.BuildSampleStatusTests(before, request, statusDesc);
                    var description = $"Sample status changed to {statusDesc} for LabOrderId {request.LabOrderId} (Reason: {request.RejectionReason ?? "N/A"}).";

                    await auditLogService.LogActivityAsync(
                        eventType: "Lab Reporting Sample Status",
                        actionName: "LAB.SampleStatusChanged",
                        description: LabReportingController.AppendTestSummary(description, affected),
                        userId: User.GetUserId(),
                        branchId: User.GetCurrentBranchId(),
                        moduleCode: "LAB",
                        referenceNo: before.BillNo,
                        referenceId: request.LabOrderId,
                        patientCode: before.PatientCode,
                        metadata: new
                        {
                            BillNo = before.BillNo,
                            StatusName = statusDesc,
                            Screen = "Microbiology Report Entry",
                            AffectedTestCount = affected.Count,
                            Tests = affected,
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
                success,
                message = success ? "Sample status updated successfully." : "Failed to update sample status."
            });
        }

        /// <summary>The Microbiology report as a PDF: the same document as Lab Report Entry, built from the Template tests.</summary>
        [HttpGet]
        public async Task<IActionResult> PrintReportPdf(int labOrderId, bool download = false, bool conditions = true, string? scope = null)
        {
            if (labOrderId <= 0)
                return BadRequest(new { message = "Valid LabOrderId is required." });

            try
            {
                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var vm = await reportPdfService.BuildAsync(labOrderId, User, scope, ReportingType);
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
                var fileName = $"MicrobiologyReport_{safeBill}{(vm.ShowNotApprovedWatermark ? "_NOT-APPROVED" : "")}.pdf";

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

        /// <summary>Records that the Microbiology report was printed (called by the Print modal).</summary>
        [HttpPost]
        public async Task<IActionResult> LogReportPrintedJson(int labOrderId, string? scope = null)
        {
            if (labOrderId <= 0)
                return Json(new { success = false });

            try
            {
                var detail = await labReportingApiClient.GetDetailAsync(labOrderId, null, ReportingType);
                if (detail == null) return Json(new { success = false });

                scope = LabReportPrintBuilder.NormalizeScope(scope);
                var summary = LabReportPrintBuilder.Summarize(detail, scope);
                var kind = summary.ShowNotApprovedWatermark ? "Provisional copy (NOT APPROVED watermark)"
                         : summary.IsFinal ? "Final report" : "Provisional report";

                await auditLogService.LogActivityAsync(
                    eventType: "Lab Reporting",
                    actionName: LabReportPdfService.PrintedAction,
                    description: $"Microbiology report printed{LabReportTypes.Marker(ReportingType)} - {kind}{(scope == LabReportPrintBuilder.ScopePending ? " " + LabReportPdfService.PendingCopyMarker : scope == LabReportPrintBuilder.ScopeApproved ? " (approved tests only)" : "")} - for patient {detail.PatientName} ({detail.PatientCode}). Order: {detail.BillNo}, Token: {detail.TokenNo}. {summary.IncludedTestCount} test(s) on the printout.",
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
                        Screen = "Microbiology Report Entry",
                        IsFinal = summary.IsFinal,
                        NotApprovedWatermark = summary.ShowNotApprovedWatermark,
                        TestsPrinted = summary.IncludedTestCount,
                        TestsNotPrinted = summary.ExcludedTestCount
                    });

                return Json(new { success = true });
            }
            catch
            {
                return Json(new { success = false });
            }
        }
    }
}
