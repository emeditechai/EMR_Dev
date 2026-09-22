using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Pathologist Dashboard (LAB menu). Only a user with IsPathologist = 1 who is assigned to the current branch can
/// open it. What they see is scoped by their Department Access, their Test Categories and the Pathologist Approval
/// Flow; sign-off is sequential when the flow defines more than one level.
/// </summary>
[Authorize]
public class PathologistDashboardController(
    IPathologistDashboardApiClient apiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    ILabReportEmailService labReportEmailService) : Controller
{
    private static readonly HashSet<string> Statuses = new(StringComparer.OrdinalIgnoreCase) { "PENDING", "MINE", "APPROVED", "ALL" };

    private const string DeniedMessage =
        "This dashboard is not available: it is open only to a pathologist of this branch, and only while "
        + "\"Pathologist approval required\" is switched on in Hospital Settings.";

    private int CurrentBranchId() => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

    /// <summary>
    /// Hospital Settings &gt; LAB &gt; "Pathologist approval required" for the current branch. With it off, the branch
    /// approves from the Report Entry screen instead, so this dashboard is closed.
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
    /// The access gate: the branch must require pathologist approval, and the user must be a pathologist assigned
    /// to that branch (checked against the API, which reads the database).
    /// </summary>
    private async Task<PathologistAccessResult?> GetAccessAsync()
    {
        try
        {
            if (!await PathologistApprovalRequiredAsync()) return null;

            var access = await apiClient.GetAccessAsync(User.GetUserId(), CurrentBranchId());
            return access.Profile is { IsPathologist: true, HasBranchAccess: true } ? access : null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var access = await GetAccessAsync();
        if (access == null) return View("AccessDenied", await BuildDeniedAsync());

        return View(access);
    }

    [HttpGet]
    public async Task<IActionResult> GetHeadersJson(DateTime? fromDate, DateTime? toDate, string? dateBasis = "BookingDate",
        string? search = null, int? departmentId = null, int? categoryId = null, string? statusFilter = "PENDING")
    {
        if (await GetAccessAsync() == null)
            return Json(new { success = false, message = DeniedMessage });

        var from = (fromDate ?? DateTime.Today).Date;
        var to = (toDate ?? from).Date.AddDays(1).AddSeconds(-1);
        if (to < from) (from, to) = (to.Date, from.Date.AddDays(1).AddSeconds(-1));

        var basis = string.Equals(dateBasis, "ValidatedDate", StringComparison.OrdinalIgnoreCase) ? "ValidatedDate" : "BookingDate";
        var status = statusFilter != null && Statuses.Contains(statusFilter) ? statusFilter.ToUpperInvariant() : "PENDING";

        try
        {
            var result = await apiClient.GetHeadersAsync(User.GetUserId(), CurrentBranchId(), from, to, basis, search, departmentId, categoryId, status);
            return Json(new { success = true, stats = result.Stats, bills = result.Bills });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>The sign-off screen for one bill (the Report Entry equivalent for a pathologist).</summary>
    [HttpGet]
    public async Task<IActionResult> Approve(int labOrderId, bool embed = false)
    {
        var access = await GetAccessAsync();
        if (access == null) return View("AccessDenied", await BuildDeniedAsync());

        if (labOrderId <= 0) return RedirectToAction(nameof(Index));

        var detail = await apiClient.GetDetailAsync(labOrderId, User.GetUserId(), CurrentBranchId());
        if (detail?.Bill == null)
        {
            TempData["ErrorMessage"] = "This bill has no test within your department / test-category access.";
            return RedirectToAction(nameof(Index));
        }

        ViewData["Profile"] = access.Profile;
        // embed=true: rendered inside the dashboard's sign-off modal (iframe) - same content, chrome-less layout.
        ViewData["Embed"] = embed;
        return View(detail);
    }

    [HttpGet]
    public async Task<IActionResult> GetDetailJson(int labOrderId)
    {
        if (await GetAccessAsync() == null)
            return Json(new { success = false, message = DeniedMessage });

        try
        {
            var detail = await apiClient.GetDetailAsync(labOrderId, User.GetUserId(), CurrentBranchId());
            if (detail?.Bill == null) return Json(new { success = false, message = "Lab order not found in your scope." });
            return Json(new { success = true, bill = detail.Bill, tests = detail.Tests, history = detail.History });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    public class ApproveRequestModel
    {
        public int LabOrderId { get; set; }
        public List<long> SamplecollectionIds { get; set; } = [];
        public string? Remarks { get; set; }
    }

    [HttpPost]
    public async Task<IActionResult> ApproveJson([FromBody] ApproveRequestModel model)
    {
        var access = await GetAccessAsync();
        if (access == null)
            return Json(new { success = false, message = DeniedMessage });

        if (model == null || model.LabOrderId <= 0 || model.SamplecollectionIds == null || model.SamplecollectionIds.Count == 0)
            return Json(new { success = false, message = "Select at least one test to approve." });

        var branchId = CurrentBranchId();
        var userId = User.GetUserId();

        try
        {
            // "before" snapshot so the audit entry can name the tests and the level signed
            var before = await apiClient.GetDetailAsync(model.LabOrderId, userId, branchId);
            if (before?.Bill == null) return Json(new { success = false, message = "Lab order not found in your scope." });

            var (result, error) = await apiClient.ApproveAsync(new PathologistApproveRequest
            {
                LabOrderId = model.LabOrderId,
                SamplecollectionIds = model.SamplecollectionIds.Distinct().ToList(),
                UserId = userId,
                BranchId = branchId,
                Remarks = string.IsNullOrWhiteSpace(model.Remarks) ? null : model.Remarks.Trim()
            });

            if (error != null) return Json(new { success = false, message = error });

            var signed = before.Tests.Where(t => model.SamplecollectionIds.Contains(t.SamplecollectionID)).ToList();
            await LogAsync(before.Bill, signed, result, access.Profile, model.Remarks);

            var final = result?.FinalApprovedCount ?? 0;
            var count = result?.SignedCount ?? 0;

            // A test reached its last level: the whole bill may be final now - email the patient's report.
            if (final > 0)
                labReportEmailService.QueueIfFinal(model.LabOrderId, User, LabReportEmailTriggers.PathologistApproval);
            var message = final == count
                ? $"{count} test(s) approved. The report is now final."
                : $"{count} test(s) signed at your level. {(final > 0 ? $"{final} became final; t" : "T")}he remaining test(s) still need the next level's approval.";

            return Json(new { success = true, signedCount = count, finalCount = final, message });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>Audit entry in the bill's activity trail. A logging failure never fails the sign-off.</summary>
    private async Task LogAsync(PathologistBillDto bill, List<PathologistTestDto> tests, PathologistApproveResult? result,
        PathologistProfileDto? profile, string? remarks)
    {
        try
        {
            static string Trim(string? v) { var t = (v ?? string.Empty).Trim(); return t.Length > 200 ? t[..200] + "…" : t; }

            var entries = tests.Select(t => new
            {
                SampleCollectionId = t.SamplecollectionID,
                InvestigationId = t.InvestigationID,
                t.TestName,
                ProfileName = t.GroupName,
                Change = t.NextLevelNo >= t.TotalLevels ? "Approved (final level)" : $"Signed level {t.NextLevelNo} of {t.TotalLevels}",
                FromStatus = "Validated",
                ToStatus = t.NextLevelNo >= t.TotalLevels ? "Approved" : $"Level {t.NextLevelNo}/{t.TotalLevels} signed",
                NewValue = Trim(t.TestValue),
                Flag = string.IsNullOrWhiteSpace(t.AbnormalFlag) ? null : t.AbnormalFlag,
                Reason = string.IsNullOrWhiteSpace(remarks) ? null : Trim(remarks)
            }).ToList();

            var isFinal = (result?.FinalApprovedCount ?? 0) == (result?.SignedCount ?? 0) && (result?.SignedCount ?? 0) > 0;
            var levelText = tests.Count > 0 ? $"Level {tests[0].NextLevelNo} of {tests[0].TotalLevels}" : "Sign-off";
            var names = string.Join(", ", tests.Select(t => t.TestName));
            var description = $"Pathologist sign-off ({levelText}) by {profile?.FullName ?? "pathologist"}"
                            + $"{(string.IsNullOrWhiteSpace(profile?.RegistrationNo) ? "" : $" [{profile!.RegistrationNo}]")}"
                            + $" for patient {bill.PatientName} ({bill.PatientCode}). Order: {bill.BillNo}, Token: {bill.TokenNo}. "
                            + $"{(isFinal ? "The report is now final." : "Awaiting the next level.")} Tests ({tests.Count}): {names}";
            if (description.Length > 1900) description = description[..1900] + "…";

            await auditLogService.LogActivityAsync(
                eventType: "Lab Reporting",
                actionName: isFinal ? "LAB.ReportApproved" : "LAB.PathologistLevelSigned",
                description: description,
                userId: User.GetUserId(),
                branchId: CurrentBranchId(),
                moduleCode: "LAB",
                referenceNo: bill.BillNo,
                referenceId: bill.LabOrderId,
                patientCode: bill.PatientCode,
                metadata: new
                {
                    bill.LabOrderId,
                    bill.BillNo,
                    bill.TokenNo,
                    Pathologist = profile?.FullName,
                    profile?.RegistrationNo,
                    result?.SignedCount,
                    result?.FinalApprovedCount,
                    Remarks = remarks,
                    Tests = entries
                });
        }
        catch
        {
            // audit only
        }
    }

    private async Task<PathologistDeniedViewModel> BuildDeniedAsync()
    {
        var userId = User.GetUserId();
        var user = await dbContext.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == userId);
        return new PathologistDeniedViewModel
        {
            UserName = user?.FullName ?? User.Identity?.Name ?? "You",
            IsPathologist = user?.IsPathologist ?? false,
            ApprovalRequiredForBranch = await PathologistApprovalRequiredAsync()
        };
    }
}

public class PathologistDeniedViewModel
{
    public string UserName { get; set; } = string.Empty;
    public bool IsPathologist { get; set; }
    /// <summary>False when the branch does not require pathologist approval - the dashboard is switched off.</summary>
    public bool ApprovalRequiredForBranch { get; set; }
}
