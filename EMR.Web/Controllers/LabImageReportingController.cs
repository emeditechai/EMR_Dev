using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
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
    [Authorize]
    [EMR.Web.Filters.LabReportingAccess]
    public class LabImageReportingController(
        ILabReportingApiClient labReportingApiClient,
        ILabOrderApiClient labOrderApiClient,
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabSampleRejectionReasonApiClient rejectionReasonApiClient,
        ILabDescriptiveTestTemplateApiClient templateApiClient,
        IAuditLogService auditLogService,
        ILabReportEmailService labReportEmailService,
        EMR.Web.Data.ApplicationDbContext dbContext,
        ILabReportPdfService pdfService) : Controller
    {
        private int CurrentBranchId()
            => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

        private async Task<bool> PathologistApprovalRequiredAsync()
        {
            var branchId = CurrentBranchId();
            return await dbContext.HospitalSettings
                .AsNoTracking()
                .Where(s => s.BranchId == branchId)
                .Select(s => (bool?)s.PathologistApprovalRequired)
                .FirstOrDefaultAsync() ?? false;
        }

        private sealed record LabDepartmentScope(bool Restricted, HashSet<int> Ids, List<SelectListItem> Departments)
        {
            public string? Csv => Restricted ? string.Join(",", Ids.OrderBy(i => i)) : null;
            public bool Allows(int? departmentId) => !Restricted || (departmentId.HasValue && Ids.Contains(departmentId.Value));
        }

        private LabDepartmentScope? _labScope;

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

            var scopedIds = scopedDepts
                .Select(x => int.Parse(x.Value))
                .ToHashSet();

            _labScope = new LabDepartmentScope(true, scopedIds, scopedDepts);
            return _labScope;
        }

        private static void ApplyDepartmentScope(LabReportingOrderDetailDto detail, LabDepartmentScope scope)
        {
            if (!scope.Restricted || detail.Items == null) return;
            detail.Items = detail.Items.Where(i => scope.Allows(i.DepartmentID)).ToList();
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
            int branchId = CurrentBranchId();

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv, reportingType: "Image");

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

            var today = DateTime.Today;
            var effectiveFrom = fromDate ?? today;
            var effectiveTo = toDate.HasValue
                ? (toDate.Value.TimeOfDay == TimeSpan.Zero ? toDate.Value.Date.AddDays(1).AddSeconds(-1) : toDate.Value)
                : today.AddDays(1).AddSeconds(-1);

            var scope = await GetLabDepartmentScopeAsync();
            if (departmentId.HasValue && !scope.Allows(departmentId)) departmentId = null;

            var headerResult = await labReportingApiClient.GetHeaderListAsync(
                branchId, effectiveFrom, effectiveTo, dateFilterType, statusFilter, search, departmentId, categoryId, subCategoryId, scope.Csv, reportingType: "Image");

            return Json(new
            {
                success = true,
                stats = headerResult.Stats,
                headers = headerResult.Headers
            });
        }

        [HttpGet]
        public async Task<IActionResult> Entry(int labOrderId)
        {
            if (labOrderId <= 0)
                return RedirectToAction(nameof(Index));

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Image");
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Reporting order details not found or no eligible collected in-house tests.";
                return RedirectToAction(nameof(Index));
            }

            var scope = await GetLabDepartmentScopeAsync();
            ApplyDepartmentScope(detail, scope);
            if (scope.Restricted && (detail.Items == null || detail.Items.Count == 0))
            {
                TempData["ErrorMessage"] = "This order has no test in your departments (User Master > Department Access).";
                return RedirectToAction(nameof(Index));
            }

            // Keep only Image investigations
            detail.Items = detail.Items?
                .Where(i => string.Equals(i.ReportingType?.Trim(), "Image", StringComparison.OrdinalIgnoreCase))
                .ToList() ?? new();

            if (detail.Items.Count == 0)
            {
                TempData["ErrorMessage"] = "This order does not contain any eligible Image report investigations.";
                return RedirectToAction(nameof(Index));
            }

            var statuses = await labReportingApiClient.GetStatusesAsync();
            var sampleStatuses = await sampleCollectionApiClient.GetStatusesAsync();
            var companyId = User.GetCompanyId();
            var rejectionReasons = (await rejectionReasonApiClient.GetListAsync(status: true, companyId: companyId)).ToList();

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
        public async Task<IActionResult> GetTemplateJson(int testId, int labOrderId, long sampleCollectionId, bool forceDefault = false)
        {
            if (testId <= 0 || labOrderId <= 0)
                return Json(new { success = false, message = "Valid testId and labOrderId are required." });

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Image");
            if (detail == null)
                return Json(new { success = false, message = "Order not found." });

            var item = detail.Items?.FirstOrDefault(x => x.SamplecollectionID == sampleCollectionId)
                       ?? detail.Items?.FirstOrDefault(x => x.InvestigationID == testId);

            // If already entered and not forcing default reset, return the saved HTML!
            if (!forceDefault && !string.IsNullOrWhiteSpace(item?.TemplateHtml))
            {
                return Json(new
                {
                    success = true,
                    isSaved = true,
                    html = item.TemplateHtml,
                    testId = item.InvestigationID,
                    testName = item.TestName,
                    testCode = item.TestCode,
                    sampleCollectionId = item.SamplecollectionID,
                    statusId = item.ReportStatusId,
                    statusName = item.ReportStatusName
                });
            }

            // Otherwise load template sections from LabDescriptiveTestTemplate
            var sections = (await templateApiClient.GetByTestIdAsync(testId)).ToList();
            var firstSection = sections.FirstOrDefault();

            var replacements = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["{{PatientName}}"] = detail.PatientName ?? "",
                ["{{PatientAge}}"] = detail.Age.HasValue ? $"{detail.Age} Y" : "",
                ["{{PatientGender}}"] = detail.Gender ?? "",
                ["{{UHID}}"] = detail.PatientCode ?? "",
                ["{{PatientCode}}"] = detail.PatientCode ?? "",
                ["{{StudyDate}}"] = item?.Samplecollectiondate?.ToString("dd-MMM-yyyy") ?? detail.BookingDateTime?.ToString("dd-MMM-yyyy") ?? DateTime.Today.ToString("dd-MMM-yyyy"),
                ["{{ReferringDoctor}}"] = detail.ReferralDoctorName ?? "Self",
                ["{{Modality}}"] = firstSection?.Modality ?? "Radiology",
                ["{{BodyPart}}"] = firstSection?.Body_Part ?? "",
                ["{{Laterality}}"] = firstSection?.Laterality ?? "N/A",
                ["{{ViewsProjections}}"] = firstSection?.Views_Projections ?? "Standard",
                ["{{ContrastAgent}}"] = firstSection?.Contrast_Agent ?? (firstSection?.Contrast_Required == true ? "Contrast Administered" : "None"),
                ["{{ClinicalIndication}}"] = "Clinical evaluation / investigation",
                ["{{SliceThickness}}"] = "5",
                ["{{DLP}}"] = "350",
                ["{{CTDIvol}}"] = "15",
                ["{{FieldStrength}}"] = "1.5 Tesla",
                ["{{Sequences}}"] = "Axial T1, T2, FLAIR, DWI, Coronal T2",
                ["{{Transducer}}"] = "Broadband curved array transducer",
                ["{{GestationalAge}}"] = "",
                ["{{ContrastVolume}}"] = "60 ml",
                ["{{ContrastPhase}}"] = "Venous phase"
            };

            var sb = new StringBuilder();
            if (sections.Count > 0)
            {
                foreach (var sec in sections.OrderBy(s => s.Section_Sequence))
                {
                    string secContent = sec.Default_Content_Html ?? "<p>Unremarkable.</p>";
                    foreach (var (tag, val) in replacements)
                    {
                        secContent = secContent.Replace(tag, val, StringComparison.OrdinalIgnoreCase);
                    }

                    sb.Append($"<p><strong>{sec.Section_Name.ToUpper()}:</strong></p>");
                    sb.Append(secContent);
                    sb.Append("<p><br></p>");
                }
            }
            else
            {
                // Fallback default structure if no template is defined yet
                sb.Append("<p><strong>CLINICAL INDICATION:</strong></p>");
                sb.Append($"<p>{detail.PatientName}, {detail.Age} Y/{detail.Gender}, referred for clinical evaluation.</p><p><br></p>");
                sb.Append("<p><strong>TECHNIQUE:</strong></p>");
                sb.Append("<p>Standard diagnostic imaging protocol performed.</p><p><br></p>");
                sb.Append("<p><strong>FINDINGS:</strong></p>");
                sb.Append("<p>Visualized structures demonstrate normal anatomical morphology and signal characteristics. No focal abnormality identified.</p><p><br></p>");
                sb.Append("<p><strong>IMPRESSION:</strong></p>");
                sb.Append($"<p>Normal study of {item?.TestName ?? "investigation"}.</p><p><br></p>");
                sb.Append("<p><strong>RECOMMENDATION:</strong></p>");
                sb.Append("<p>Clinical correlation recommended.</p>");
            }

            return Json(new
            {
                success = true,
                isSaved = false,
                html = sb.ToString(),
                testId = item?.InvestigationID ?? testId,
                testName = item?.TestName ?? firstSection?.Test_Name ?? "Investigation",
                testCode = item?.TestCode ?? firstSection?.Test_Code ?? "",
                sampleCollectionId = item?.SamplecollectionID ?? sampleCollectionId,
                statusId = item?.ReportStatusId ?? 0,
                statusName = item?.ReportStatusName ?? "Pending Entry",
                modality = firstSection?.Modality,
                bodyPart = firstSection?.Body_Part,
                placeholders = replacements
            });
        }

        [HttpPost]
        public async Task<IActionResult> SaveReportJson([FromBody] SaveLabReportingRequestDto request)
        {
            if (request == null || request.LabOrderId <= 0)
                return Json(new { success = false, message = "Invalid request payload." });

            if (request.ReportStatusId <= 0)
                return Json(new { success = false, message = "Invalid ReportStatusId." });

            if (request.ReportStatusId == 5 && await PathologistApprovalRequiredAsync())
            {
                return Json(new
                {
                    success = false,
                    message = "Pathologist approval is required for this branch. Approve the report from the Pathologist Dashboard."
                });
            }

            if (request.Entries == null || request.Entries.Count == 0)
            {
                return Json(new { success = false, message = "No report entries provided." });
            }

            foreach (var entry in request.Entries)
            {
                entry.ReportingType = "Image";
                if (string.IsNullOrWhiteSpace(entry.TestValue))
                {
                    entry.TestValue = "Report Entered";
                }
            }

            // Best-effort "before" snapshot so the audit trail can record exactly which tests changed.
            LabReportingOrderDetailDto? detailBeforeSave = null;
            try { detailBeforeSave = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), "Image"); }
            catch { /* audit-only; must never block the save */ }

            try
            {
                var result = await labReportingApiClient.SaveEntryAsync(request);
                if (result)
                {
                    // For approvals: record sign-off so printed signature follows this route.
                    if (request.ReportStatusId == 5)
                    {
                        try
                        {
                            await labReportingApiClient.RecordEntryApprovalAsync(
                                request.LabOrderId,
                                request.Entries.Select(e => e.SamplecollectionID),
                                User.GetUserId(),
                                CurrentBranchId());
                        }
                        catch (HttpRequestException) { /* never block the save */ }

                        // The whole bill may be final: email the patient's report (background, when enabled).
                        labReportEmailService.QueueIfFinal(request.LabOrderId, User, LabReportEmailTriggers.EntryApproval);
                    }

                    // Structured audit log – shows in the "i" Audit History modal.
                    try
                    {
                        var detail = await labReportingApiClient.GetDetailAsync(request.LabOrderId, CurrentBranchId(), "Image");

                        string statusName = request.ReportStatusId switch
                        {
                            1 => "saved as Draft",
                            2 => "saved and submitted",
                            3 => "validated",
                            4 => "marked for re-collection",
                            5 => "approved",
                            _ => "saved"
                        };

                        string actionName = request.ReportStatusId switch
                        {
                            1 => "LAB.ReportDraftSaved",
                            2 => "LAB.ReportEntryCompleted",
                            3 => "LAB.ReportValidated",
                            4 => "LAB.ReportReCollected",
                            5 => "LAB.ReportApproved",
                            _ => "LAB.ReportSaved"
                        };

                        var testChanges = BuildImageReportTestChanges(detailBeforeSave, detail);
                        var billNo     = detail?.BillNo     ?? detailBeforeSave?.BillNo;
                        var patCode    = detail?.PatientCode ?? detailBeforeSave?.PatientCode;
                        var tokenNo    = detail?.TokenNo    ?? detailBeforeSave?.TokenNo;
                        var baseDesc   = $"Image report {statusName} for patient {detail?.PatientName ?? "Unknown"} ({patCode}). Order: {billNo}, Token: {tokenNo}. Entered results for {request.Entries?.Count ?? 0} test(s).";

                        await auditLogService.LogActivityAsync(
                            eventType:   "Lab Reporting",
                            actionName:  actionName,
                            description: AppendImageTestSummary(baseDesc, testChanges),
                            userId:      User.GetUserId(),
                            branchId:    CurrentBranchId(),
                            moduleCode:  "LAB",
                            referenceNo: billNo,
                            referenceId: request.LabOrderId,
                            patientCode: patCode,
                            metadata: new
                            {
                                request.LabOrderId,
                                BillNo           = billNo,
                                TokenNo          = tokenNo,
                                request.ReportStatusId,
                                StatusName       = statusName,
                                ResultCount      = request.Entries?.Count ?? 0,
                                ChangedTestCount = testChanges.Count,
                                Tests            = testChanges
                            });
                    }
                    catch { /* Non-blocking logging – never fail the user action */ }

                    return Json(new { success = true, message = "Image report saved successfully!" });
                }
                return Json(new { success = false, message = "Failed to save report. Please check the entries." });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = "Error saving report: " + ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> Print(int labOrderId, long? sampleCollectionId = null)
        {
            if (labOrderId <= 0)
                return RedirectToAction(nameof(Index));

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, CurrentBranchId(), "Image");
            if (detail == null)
            {
                TempData["ErrorMessage"] = "Order not found.";
                return RedirectToAction(nameof(Index));
            }

            // Filter to image investigations
            detail.Items = detail.Items?
                .Where(i => string.Equals(i.ReportingType?.Trim(), "Image", StringComparison.OrdinalIgnoreCase))
                .ToList() ?? new();

            if (sampleCollectionId.HasValue)
            {
                detail.Items = detail.Items
                    .Where(i => i.SamplecollectionID == sampleCollectionId.Value)
                    .ToList();
            }

            var branchId = CurrentBranchId();
            var settings = await dbContext.HospitalSettings
                .Where(s => s.BranchId == branchId && s.IsActive)
                .FirstOrDefaultAsync();

            ViewBag.HospitalName = settings?.HospitalName ?? "eMeditech Hospital";
            ViewBag.HospitalType = settings?.HospitalType;
            ViewBag.LogoPath = settings?.LogoPath;
            ViewBag.NabhStatus = settings?.NabhStatus;
            ViewBag.NabhCertificateNo = settings?.NabhCertificateNo;
            ViewBag.Address = settings?.Address;
            ViewBag.ContactNumber = settings?.ContactNumber1;
            ViewBag.Email = settings?.EmailAddress;
            ViewBag.Website = settings?.Website;
            ViewBag.RegistrationNumber = settings?.RegistrationNumber;
            ViewBag.PrintedBy = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name ?? "System";

            try
            {
                var signoffLevels = await labReportingApiClient.GetSignoffPanelAsync(labOrderId, branchId, reportingType: "Image");
                if (signoffLevels != null && signoffLevels.Count > 0)
                {
                    foreach (var level in signoffLevels)
                    {
                        if (!string.IsNullOrWhiteSpace(level.SignaturePath))
                        {
                            var sigBytes = pdfService.LoadSignature(level.SignaturePath);
                            if (sigBytes is { Length: > 0 })
                            {
                                var ext = Path.GetExtension(level.SignaturePath).TrimStart('.').ToLowerInvariant();
                                if (ext == "jpg") ext = "jpeg";
                                level.SignaturePath = $"data:image/{ext};base64,{Convert.ToBase64String(sigBytes)}";
                            }
                            else
                            {
                                level.SignaturePath = null;
                            }
                        }
                    }
                }
                ViewBag.SignoffLevels = signoffLevels;
            }
            catch { }

            return View(detail);
        }

        // ── Audit helpers (Image Reporting) ──────────────────────────────────────

        private const int AuditImageValueMaxLength = 200;

        private sealed record ImageAuditTestEntry
        {
            public long   SampleCollectionId { get; init; }
            public int    InvestigationId    { get; init; }
            public string? TestName          { get; init; }
            public string  Change            { get; init; } = string.Empty;
            public string? FromStatus        { get; init; }
            public string? ToStatus          { get; init; }
            public bool?   ValueChanged      { get; init; }
            public string? OldValue          { get; init; }
            public string? NewValue          { get; init; }
        }

        private static string ImageReportStatusLabel(int statusId) => statusId switch
        {
            0 => "Pending Entry",
            1 => "Draft",
            2 => "Submitted",
            3 => "Validated",
            4 => "Re-collected",
            5 => "Approved",
            _ => $"Status {statusId}"
        };

        private static string ImageAuditNorm(string? value)
        {
            var v = (value ?? string.Empty).Trim();
            return v.Length > AuditImageValueMaxLength ? v[..AuditImageValueMaxLength] + "\u2026" : v;
        }

        /// <summary>Compares the order before/after a save and lists the tests whose value or status changed.</summary>
        private static List<ImageAuditTestEntry> BuildImageReportTestChanges(
            LabReportingOrderDetailDto? before, LabReportingOrderDetailDto? after)
        {
            var changes = new List<ImageAuditTestEntry>();
            if (before?.Items == null || after?.Items == null) return changes;

            var beforeBySample = before.Items
                .GroupBy(i => i.SamplecollectionID)
                .ToDictionary(g => g.Key, g => g.First());

            foreach (var a in after.Items)
            {
                if (!beforeBySample.TryGetValue(a.SamplecollectionID, out var b)) continue;

                var oldValue  = (b.TestValue ?? string.Empty).Trim();
                var newValue  = (a.TestValue ?? string.Empty).Trim();
                var oldStatus = oldValue.Length == 0 ? 0 : b.ReportStatusId;
                var newStatus = newValue.Length == 0 ? 0 : a.ReportStatusId;

                var valueChanged  = !string.Equals(oldValue, newValue, StringComparison.Ordinal);
                var statusChanged = oldStatus != newStatus;
                if (!valueChanged && !statusChanged) continue;

                string change;
                if (newValue.Length == 0 && oldValue.Length > 0) change = "Cleared";
                else if (statusChanged) change = ImageReportStatusLabel(newStatus);
                else change = "Edited";

                changes.Add(new ImageAuditTestEntry
                {
                    SampleCollectionId = a.SamplecollectionID,
                    InvestigationId    = a.InvestigationID,
                    TestName           = a.TestName,
                    Change             = change,
                    FromStatus         = ImageReportStatusLabel(oldStatus),
                    ToStatus           = ImageReportStatusLabel(newStatus),
                    ValueChanged       = valueChanged,
                    OldValue           = ImageAuditNorm(oldValue),
                    NewValue           = ImageAuditNorm(newValue)
                });
            }

            return changes;
        }

        /// <summary>Appends "Tests: a, b, c" to a description, capped at 1900 chars.</summary>
        private static string AppendImageTestSummary(string description, List<ImageAuditTestEntry> tests)
        {
            if (tests.Count == 0) return description;

            var names  = tests.Select(t => t.TestName).Where(n => !string.IsNullOrWhiteSpace(n)).ToList();
            var suffix = $" Tests affected ({tests.Count}): {string.Join(", ", names)}.";
            const int limit = 1900;
            if (description.Length + suffix.Length > limit)
                suffix = suffix[..Math.Max(0, limit - description.Length - 1)] + "\u2026";

            return description + suffix;
        }
    }
}
