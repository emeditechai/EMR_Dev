using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Lab Report Dispatch dashboard (LAB menu): bill wise report readiness, search and print.</summary>
[Authorize]
public class LabReportDispatchController(
    ILabReportDispatchApiClient dispatchApiClient,
    ILabReportingApiClient labReportingApiClient,
    ILabReportPdfService reportPdfService,
    IAuditLogService auditLogService,
    IQueryStringEncryptionService encryptionService,
    IDbConnectionFactory db,
    EMR.Web.Services.Notifications.INotificationService notifications) : Controller
{
    /// <summary>A franchise login works only on the bills it created or that are for its own franchise (2259); every other login: all bills.</summary>
    private int? OwnBillsOnly => User.IsFranchiseUser() ? User.GetUserId() : null;

    private async Task<bool> MayOpenAsync(int labOrderId)
    {
        if (OwnBillsOnly is not int userId) return true;
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM dbo.LabOrder WHERE LabOrderId = @labOrderId AND (CreatedBy = @userId OR (AgentType = 'F' AND B2BAgentID = @franchiseId))",
            new { labOrderId, userId, franchiseId = User.GetFranchiseId() }) > 0;
    }

    private static readonly HashSet<string> DispatchStatuses = new(StringComparer.OrdinalIgnoreCase)
        { "ALL", "READY", "PARTIAL", "AWAITING", "INPROGRESS", "NOTSTARTED", "PRINTED", "NOTPRINTED" };

    private const string DueMessage = "Unable to print the report. Please clear the outstanding due first.";

    [HttpGet]
    public IActionResult Index()
    {
        // Initial load = today, by billing date. The list itself is fetched by GetDashboardJson.
        return View(new LabReportDispatchPageViewModel
        {
            FromDate = DateTime.Today,
            ToDate = DateTime.Today
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetDashboardJson(
        DateTime? fromDate,
        DateTime? toDate,
        string? dateBasis = "BillingDate",
        string? search = null,
        string? dispatchStatus = "ALL",
        string? clientType = "ALL")
    {
        int branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

        var from = (fromDate ?? DateTime.Today).Date;
        var to = (toDate ?? from).Date.AddDays(1).AddSeconds(-1);
        if (to < from) (from, to) = (to.Date, from.Date.AddDays(1).AddSeconds(-1));

        var basis = string.Equals(dateBasis, "ApprovedDate", StringComparison.OrdinalIgnoreCase) ? "ApprovedDate" : "BillingDate";
        var status = dispatchStatus != null && DispatchStatuses.Contains(dispatchStatus) ? dispatchStatus.ToUpperInvariant() : "ALL";
        var client = clientType?.ToUpperInvariant() is "B2B" or "B2C" ? clientType!.ToUpperInvariant() : "ALL";

        try
        {
            var result = await dispatchApiClient.GetDashboardAsync(branchId, from, to, basis, search, status, client, OwnBillsOnly);
            var encMap = result.Rows.ToDictionary(
                r => r.LabOrderId,
                r => encryptionService.EncryptParameters(new Dictionary<string, string?> { ["labOrderId"] = r.LabOrderId.ToString() }));
            // 2465: B2C bills with a due - the branch's "Allow Print Lab Report in Due" and the newest approval request
            var dueIds = result.Rows.Where(r => r.BalanceDue > 0 && !string.Equals(r.BillingType, "B2B", StringComparison.OrdinalIgnoreCase))
                                    .Select(r => r.LabOrderId).ToList();
            var duePrint = new Dictionary<int, object>();
            if (dueIds.Count > 0)
            {
                try
                {
                    foreach (var s in await dispatchApiClient.GetDuePrintStatesAsync(dueIds))
                        duePrint[s.LabOrderId] = new
                        {
                            allow = s.AllowPrintInDue, status = s.Status, remarks = s.Remarks, requestedBy = s.RequestedByName,
                            requestedAt = s.Requested_Date, actionedBy = s.ActionedByName, actionedAt = s.Actioned_Date
                        };
                }
                catch (HttpRequestException) { /* the list still shows; due bills stay locked */ }
            }
            return Json(new { success = true, stats = result.Stats, rows = result.Rows, encMap, duePrint });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>Every test of one bill, with its collection / entry / approval stamps (the list's view-tests modal).</summary>
    [HttpGet]
    public async Task<IActionResult> GetBillTestsJson(int labOrderId)
    {
        if (labOrderId <= 0) return Json(new { success = false, message = "Valid LabOrderId is required." });
        if (!await MayOpenAsync(labOrderId)) return Json(new { success = false, message = "This bill is not available to you." });

        try
        {
            var tests = await dispatchApiClient.GetBillTestsAsync(labOrderId);

            // Which PDFs the bill can print (Lab Report / Microbiology Report), and the tests of the Microbiology one.
            List<string>? reports = null;
            var templateSampleIds = new List<long>();
            try
            {
                reports = await reportPdfService.GetPrintableReportTypesAsync(labOrderId);
                var template = await labReportingApiClient.GetDetailAsync(labOrderId, null, LabReportTypes.Template);
                if (template?.Items != null) templateSampleIds = template.Items.Select(i => i.SamplecollectionID).ToList();
            }
            catch (HttpRequestException) { /* the page falls back to the tests' own types */ }

            return Json(new { success = true, tests, reports, templateSampleIds });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>
    /// Opens the existing Lab Bill print page for this order and records the print server-side
    /// (so a bill printed from the dispatch desk is always counted, whatever the browser does afterwards).
    /// A bill can always be printed - it is what the patient pays against.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> PrintBill(int labOrderId)
    {
        if (labOrderId <= 0) return BadRequest("Valid LabOrderId is required.");
        if (!await MayOpenAsync(labOrderId)) return Forbid();

        await LogPrintAsync(labOrderId, "LAB.BillPrinted", "Lab bill printed from the Report Dispatch dashboard.", null);
        return RedirectToAction("PrintBill", "LabOrderBooking", new { labOrderId });
    }

    /// <summary>
    /// The Lab Report PDF for the dispatch desk.
    /// A report is released only when the bill is fully paid, and that rule is enforced here, on the server,
    /// so it holds even if the request is made outside the dashboard.
    /// The modal preview uses mode=preview (not counted); Print / Download record the print before streaming,
    /// so the dashboard's print count never depends on a follow-up call from the browser.
    /// Every copy after the first carries a DUPLICATE marker.
    /// </summary>
    [HttpGet]
    /// <summary>
    /// Action > Send Report (SQLScripts/2392): the final (all tests approved) report to the patient by WhatsApp and e-mail,
    /// through the same senders as the automatic send after approval - sent again if it already went. Refused while the
    /// bill has a due or any test is not approved. Each channel reports its own outcome (switched off, no number, sent...).
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendReport(int labOrderId)
    {
        if (labOrderId <= 0) return Json(new { success = false, message = "Valid LabOrderId is required." });
        if (!await MayOpenAsync(labOrderId)) return Json(new { success = false, message = "This bill is not available to you." });

        var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
        if (detail == null) return Json(new { success = false, message = "Lab report details not found." });
        if (detail.BalanceDue > 0)
            return Json(new { success = false, message = $"Bill {detail.BillNo} has a due of Rs. {detail.BalanceDue:N2}. The report can be sent once the due is cleared." });
        var tests = detail.Items ?? [];
        if (tests.Count == 0 || tests.Any(i => i.ReportStatusId != 5))
            return Json(new { success = false, message = $"Only an approved report can be sent: {tests.Count(i => i.ReportStatusId == 5)} of {tests.Count} test(s) of bill {detail.BillNo} are approved." });

        var whatsApp = HttpContext.RequestServices.GetRequiredService<ILabReportWhatsAppService>();
        var email = HttpContext.RequestServices.GetRequiredService<ILabReportEmailService>();
        var wa = await whatsApp.SendIfFinalAsync(labOrderId, User, LabReportEmailTriggers.DispatchSend, resend: true);
        var em = await email.SendIfFinalAsync(labOrderId, User, LabReportEmailTriggers.DispatchSend, resend: true);

        await auditLogService.LogActivityAsync(
            eventType: "Lab Report", actionName: "LAB.ReportSent",
            description: $"Report of bill {detail.BillNo} sent from Report Dispatch - WhatsApp: {wa.Status} ({wa.Message}); e-mail: {em.Status} ({em.Message}).",
            userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "LAB",
            referenceNo: detail.BillNo, referenceId: labOrderId, patientCode: detail.PatientCode);

        return Json(new
        {
            success = wa.Status == "Sent" || em.Status == "Sent",
            billNo = detail.BillNo,
            whatsApp = new { status = wa.Status, message = wa.Message },
            email = new { status = em.Status, message = em.Message }
        });
    }

    /// <summary>2465: the bill's branch allows printing in due and its newest Due Report Print request is approved.</summary>
    private async Task<bool> DuePrintApprovedAsync(int labOrderId)
    {
        try
        {
            var s = (await dispatchApiClient.GetDuePrintStatesAsync([labOrderId])).FirstOrDefault();
            return s is { AllowPrintInDue: true, Status: "A" };
        }
        catch (HttpRequestException) { return false; }
    }

    /// <summary>
    /// Action > Send Approval for Due Report Print (SQLScripts/2465): when the branch allows printing in due, asks the
    /// approvers of Approval Matrix > Due Report Print to release the report of this B2C bill. The approvers get a bell /
    /// live notification; they act on Utility > Approval Dashboard and the requester is notified back.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RequestDuePrint(int labOrderId, string? reason)
    {
        if (labOrderId <= 0) return Json(new { success = false, message = "Valid LabOrderId is required." });
        if (!await MayOpenAsync(labOrderId)) return Json(new { success = false, message = "This bill is not available to you." });
        reason = string.IsNullOrWhiteSpace(reason) ? null : reason.Trim()[..Math.Min(reason.Trim().Length, 500)];
        if (reason is null || reason.Length < 5) return Json(new { success = false, message = "Give the reason for printing with a due (at least 5 characters)." });

        LabDuePrintSubmitResult r;
        try { r = await dispatchApiClient.SubmitDuePrintAsync(labOrderId, User.GetUserId(), reason); }
        catch (HttpRequestException) { return Json(new { success = false, message = "The reporting service is unreachable. Please try again." }); }
        if (r.Request_ID <= 0) return Json(new { success = false, message = r.ErrorMessage ?? "The request could not be sent." });

        await auditLogService.LogActivityAsync(
            eventType: "Lab Report", actionName: "LAB.DuePrintRequested",
            description: $"Approval requested to print the report of bill {r.BillNo} with a due of Rs. {r.BalanceDue:N2} [Request #{r.Request_ID}]: {reason}",
            userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "LAB",
            referenceNo: r.BillNo, referenceId: labOrderId);

        if (r.ApproverIds.Count > 0)
        {
            var where = r.Scope == "C" ? "the head-office branch" : (r.BranchName ?? "the branch");
            await notifications.NotifyUsersAsync(r.ApproverIds, MasterApprovalService.NotifyCategory, "WARNING",
                $"Due Report Print awaiting approval · {r.BillNo}",
                $"{User.GetDisplayName()} asks to print the lab report of bill {r.BillNo} ({r.PatientName}) with a due of Rs. {r.BalanceDue:N2}. Reason: {reason}. Approve it on the Approval Dashboard of {where}.",
                MasterApprovalService.DashboardLink, MasterApprovalService.NotifyRef, r.Request_ID, $"APPROVAL_SUBMIT:{r.Request_ID}",
                r.BranchId, User.GetUserId());
        }
        return Json(new { success = true, message = $"Sent for approval to {r.ApproverIds.Count} approver(s). Report Print opens for bill {r.BillNo} once it is approved." });
    }

    public async Task<IActionResult> PrintReportPdf(int labOrderId, string mode = "preview", string? scope = null, string? reportingType = null)
    {
        // Numeric = the Lab Report (default, as always); Template = the Microbiology Report
        var reportType = LabReportTypes.Normalize(reportingType);
        if (labOrderId <= 0) return BadRequest(new { message = "Valid LabOrderId is required." });
        if (!await MayOpenAsync(labOrderId)) return StatusCode(StatusCodes.Status403Forbidden, new { message = "This bill is not available to you." });

        // "approved" prints only the approved tests of a partly approved bill (a clean, final-looking copy);
        // "pending" prints the validated-but-unapproved ones; the default keeps the whole printable report.
        scope = LabReportPrintBuilder.NormalizeScope(scope);

        var isPreview = string.Equals(mode, "preview", StringComparison.OrdinalIgnoreCase);
        var isDownload = string.Equals(mode, "download", StringComparison.OrdinalIgnoreCase);

        try
        {
            var vm = await reportPdfService.BuildAsync(labOrderId, User, scope, reportType);
            if (vm == null)
                return NotFound(new { message = "Lab report details not found." });

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
            var balanceDue = detail?.BalanceDue ?? 0m;
            // A B2B bill is settled with the franchise/company, not collected from the patient at the
            // counter, so it must always be printable once ready - the due rule is B2C only.
            // 2465: a B2C bill with a due prints only when the branch allows printing in due (Hospital Settings > LAB)
            // AND a Due Report Print approval for the bill is approved.
            if (balanceDue > 0 && detail?.IsB2B != true && !await DuePrintApprovedAsync(labOrderId))
            {
                return StatusCode(StatusCodes.Status402PaymentRequired, new
                {
                    message = DueMessage,
                    balanceDue,
                    billNo = detail?.BillNo,
                    patientName = detail?.PatientName
                });
            }

            if (vm.IncludedTestCount == 0)
                return Conflict(new
                {
                    message = scope switch
                    {
                        LabReportPrintBuilder.ScopeApproved => "No test of this bill is approved yet.",
                        LabReportPrintBuilder.ScopePending => "There is no validated (not yet approved) test to print.",
                        _ => "Nothing to print yet. Validate at least one test to print a report."
                    }
                });

            var pdf = LabReportPdfDocument.Generate(vm, reportPdfService.LoadLogo(vm.HospitalLogoPath));

            // Recorded only once the document exists, so a failed render is never counted as a print.
            if (!isPreview)
                await LogPrintAsync(labOrderId, LabReportPdfService.PrintedAction,
                    $"{LabReportTypes.Title(reportType)} printed{LabReportTypes.Marker(reportType)} from the Report Dispatch dashboard "
                    + $"({(vm.IsDuplicate ? $"duplicate copy, print #{vm.PrintSequence}" : "original copy")}"
                    + $"{(scope == LabReportPrintBuilder.ScopeApproved ? ", approved tests only" : "")}"
                    + $"{(scope == LabReportPrintBuilder.ScopePending ? $", {LabReportPdfService.PendingCopyMarker}" : "")}).",
                    vm.PrintSequence);

            var safeBill = new string((vm.BillNo ?? $"Order{labOrderId}").Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
            var fileName = $"{LabReportTypes.FilePrefix(reportType)}_{safeBill}{(vm.ShowNotApprovedWatermark ? "_NOT-APPROVED" : "")}{(vm.IsDuplicate ? "_DUPLICATE" : "")}.pdf";

            Response.Headers.CacheControl = "no-store";
            Response.Headers["X-Report-Status"] = vm.IsFinal ? "final" : "provisional";
            Response.Headers["X-Report-Watermark"] = vm.ShowNotApprovedWatermark ? "1" : "0";
            Response.Headers["X-Report-Tests"] = vm.IncludedTestCount.ToString();
            Response.Headers["X-Report-Duplicate"] = vm.IsDuplicate ? "1" : "0";
            Response.Headers["X-Report-Print-Sequence"] = vm.PrintSequence.ToString();
            Response.Headers["X-Report-Scope"] = scope;
            Response.Headers["Access-Control-Expose-Headers"] =
                "X-Report-Status, X-Report-Watermark, X-Report-Tests, X-Report-Duplicate, X-Report-Print-Sequence, X-Report-Scope";

            if (isDownload)
                return File(pdf, "application/pdf", fileName);

            Response.Headers.ContentDisposition = $"inline; filename=\"{fileName}\"";
            return File(pdf, "application/pdf");
        }
        catch (HttpRequestException)
        {
            return StatusCode(503, new { message = "The reporting service is unreachable. Please try again." });
        }
    }

    /// <summary>Best-effort audit entry; a logging failure must never block the print.</summary>
    private async Task LogPrintAsync(int labOrderId, string actionName, string what, int? printSequence)
    {
        try
        {
            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);

            await auditLogService.LogActivityAsync(
                eventType: "Lab Reporting",
                actionName: actionName,
                description: $"{what} Patient {detail?.PatientName} ({detail?.PatientCode}). Order: {detail?.BillNo}, Token: {detail?.TokenNo}.",
                userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(),
                moduleCode: "LAB",
                referenceNo: detail?.BillNo,
                referenceId: labOrderId,
                patientCode: detail?.PatientCode,
                metadata: new
                {
                    LabOrderId = labOrderId,
                    detail?.BillNo,
                    Source = "LabReportDispatch",
                    PrintSequence = printSequence,
                    IsDuplicate = printSequence > 1
                });
        }
        catch
        {
            // Audit only - never surface an error to the print flow.
        }
    }
}
