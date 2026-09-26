using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Un-Authorize Report (LAB menu). An approved test is frozen on the Lab Reporting Entry page; here the approval of
/// individual tests is withdrawn (Approved -> Submitted) so the value can be corrected and the normal
/// submit / validate / approve flow followed again. Every withdrawal is written to the bill's audit history.
/// </summary>
[Authorize]
public class LabUnapproveController(
    ILabUnapproveApiClient apiClient,
    IAuditLogService auditLogService,
    IQueryStringEncryptionService encryptionService) : Controller
{
    private static readonly HashSet<string> ApprovalTypes = new(StringComparer.OrdinalIgnoreCase) { "ALL", "FULL", "PARTIAL" };

    private const string ActionRetest = "RETEST";
    private const string ActionRecollect = "RECOLLECT";

    [HttpGet]
    public IActionResult Index()
    {
        return View(new LabUnapprovePageModel { FromDate = DateTime.Today, ToDate = DateTime.Today });
    }

    [HttpGet]
    public async Task<IActionResult> GetHeadersJson(DateTime? fromDate, DateTime? toDate, string? dateBasis = "ApprovedDate", string? search = null, string? approvalType = "ALL")
    {
        int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

        var from = (fromDate ?? DateTime.Today).Date;
        var to = (toDate ?? from).Date.AddDays(1).AddSeconds(-1);
        if (to < from) (from, to) = (to.Date, from.Date.AddDays(1).AddSeconds(-1));

        var basis = string.Equals(dateBasis, "BookingDate", StringComparison.OrdinalIgnoreCase) ? "BookingDate" : "ApprovedDate";
        var type = approvalType != null && ApprovalTypes.Contains(approvalType) ? approvalType.ToUpperInvariant() : "ALL";

        try
        {
            var result = await apiClient.GetHeadersAsync(branchId, from, to, basis, search, type);
            var encMap = result.Headers.ToDictionary(
                h => h.LabOrderId,
                h => encryptionService.EncryptParameters(new Dictionary<string, string?> { ["labOrderId"] = h.LabOrderId.ToString() }));
            return Json(new { success = true, stats = result.Stats, headers = result.Headers, encMap });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetDetailJson(int labOrderId)
    {
        if (labOrderId <= 0) return Json(new { success = false, message = "Valid LabOrderId is required." });

        try
        {
            var detail = await apiClient.GetDetailAsync(labOrderId);
            if (detail?.Bill == null) return Json(new { success = false, message = "Lab order not found." });
            return Json(new { success = true, bill = detail.Bill, tests = detail.Tests });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    public class UnapproveRequestModel
    {
        public int LabOrderId { get; set; }
        public List<long> SamplecollectionIds { get; set; } = [];
        public string? Reason { get; set; }
        /// <summary>What the withdrawal is for: RETEST or RECOLLECT.</summary>
        public string? Action { get; set; }
    }

    [HttpPost]
    public async Task<IActionResult> UnapproveJson([FromBody] UnapproveRequestModel model)
    {
        if (model == null || model.LabOrderId <= 0 || model.SamplecollectionIds == null || model.SamplecollectionIds.Count == 0)
            return Json(new { success = false, message = "Select at least one approved test." });

        var unapproveFor = (model.Action ?? string.Empty).Trim().ToUpperInvariant();
        if (unapproveFor != ActionRetest && unapproveFor != ActionRecollect)
            return Json(new { success = false, message = "Please select what the withdrawal is for: Re-Test or Re-Collect." });

        var reason = (model.Reason ?? string.Empty).Trim();
        if (reason.Length < 5)
            return Json(new { success = false, message = "A reason (at least 5 characters) is required to un-approve a report." });
        if (reason.Length > 500) reason = reason[..500];

        try
        {
            // "Before" snapshot for the audit trail (which tests, which value they held).
            var before = await apiClient.GetDetailAsync(model.LabOrderId);
            if (before?.Bill == null)
                return Json(new { success = false, message = "Lab order not found." });

            var requested = model.SamplecollectionIds.Distinct().ToList();
            var picked = before.Tests.Where(t => requested.Contains(t.SamplecollectionID) && t.IsApproved).ToList();
            if (picked.Count != requested.Count)
                return Json(new { success = false, message = "One or more selected tests are not approved any more. Please refresh and try again." });

            // A profile is un-approved as a whole: pull in every approved test of the selected tests' profiles.
            var profileIds = picked.Where(t => t.ProfileId.HasValue).Select(t => t.ProfileId!.Value).ToHashSet();
            if (profileIds.Count > 0)
            {
                picked = before.Tests.Where(t => t.IsApproved && (requested.Contains(t.SamplecollectionID)
                                                                   || (t.ProfileId.HasValue && profileIds.Contains(t.ProfileId.Value)))).ToList();
            }

            var (count, error) = await apiClient.UnapproveAsync(new LabUnapproveRequest
            {
                LabOrderId = model.LabOrderId,
                SamplecollectionIds = picked.Select(t => t.SamplecollectionID).ToList(),
                Reason = reason,
                Action = unapproveFor,
                UserId = User.GetUserId()
            });

            if (error != null)
                return Json(new { success = false, message = error });

            await LogAsync(before.Bill, picked, reason, unapproveFor);

            var what = count == 1 ? "1 test" : $"{count} tests";
            return Json(new
            {
                success = true,
                count,
                action = unapproveFor,
                message = unapproveFor == ActionRecollect
                    ? $"{what} un-approved for re-collection. The sample(s) are back on the Sample Collection page and the entered results were cleared."
                    : $"{what} un-approved. The result(s) can now be corrected on the Lab Reporting Entry page."
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>Audit entry in the bill's activity trail (shown by the info icon). A logging failure never fails the un-approval.</summary>
    private async Task LogAsync(LabUnapproveBillDto bill, List<LabUnapproveTestDto> tests, string reason, string unapproveFor)
    {
        try
        {
            var recollect = unapproveFor == ActionRecollect;
            var forLabel = recollect ? "Re-Collect" : "Re-Test";
            static string Trim(string? v) { var t = (v ?? string.Empty).Trim(); return t.Length > 200 ? t[..200] + "…" : t; }

            var entries = tests.Select(t => new
            {
                SampleCollectionId = t.SamplecollectionID,
                InvestigationId = t.InvestigationID,
                t.TestName,
                ProfileName = t.GroupName,
                Change = recollect ? "Approval withdrawn - re-collect" : "Approval withdrawn - re-test",
                FromStatus = "Approved",
                ToStatus = recollect ? "Re-Collect (sample)" : "Submitted",
                OldValue = Trim(t.TestValue),
                // A re-collection clears the entered result; a re-test keeps it for correction.
                NewValue = recollect ? null : Trim(t.TestValue),
                ClearedValue = recollect ? Trim(t.TestValue) : null,
                ClearedReportStatus = recollect ? "Approved" : null,
                Flag = string.IsNullOrWhiteSpace(t.AbnormalFlag) ? null : t.AbnormalFlag,
                Reason = reason
            }).ToList();

            var names = string.Join(", ", tests.Select(t => t.TestName));
            var effect = recollect
                ? "The sample(s) go back to the Sample Collection page for re-collection and the entered results were cleared."
                : "The test(s) go back to Submitted for correction on the Lab Reporting Entry page.";
            var description = $"Report approval withdrawn (un-authorized) for patient {bill.PatientName} ({bill.PatientCode}). Order: {bill.BillNo}, Token: {bill.TokenNo}. For: {forLabel}. Reason: {reason}. {effect} Tests un-approved ({tests.Count}): {names}";
            if (description.Length > 1900) description = description[..1900] + "…";

            await auditLogService.LogActivityAsync(
                eventType: "Lab Reporting",
                actionName: "LAB.ReportUnapproved",
                description: description,
                userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(),
                moduleCode: "LAB",
                referenceNo: bill.BillNo,
                referenceId: bill.LabOrderId,
                patientCode: bill.PatientCode,
                metadata: new
                {
                    bill.LabOrderId,
                    bill.BillNo,
                    bill.TokenNo,
                    StatusName = "unapproved",
                    Action = unapproveFor,
                    UnapprovedFor = forLabel,
                    Reason = reason,
                    ChangedTestCount = entries.Count,
                    Tests = entries
                });
        }
        catch
        {
            // audit only
        }
    }
}

public class LabUnapprovePageModel
{
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
}
