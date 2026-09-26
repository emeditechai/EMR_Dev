using EMR.Web.ApiClients;
using EMR.Web.Extensions;
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
    IQueryStringEncryptionService encryptionService) : Controller
{
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
            var result = await dispatchApiClient.GetDashboardAsync(branchId, from, to, basis, search, status, client);
            var encMap = result.Rows.ToDictionary(
                r => r.LabOrderId,
                r => encryptionService.EncryptParameters(new Dictionary<string, string?> { ["labOrderId"] = r.LabOrderId.ToString() }));
            return Json(new { success = true, stats = result.Stats, rows = result.Rows, encMap });
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

        try
        {
            var tests = await dispatchApiClient.GetBillTestsAsync(labOrderId);
            return Json(new { success = true, tests });
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
    public async Task<IActionResult> PrintReportPdf(int labOrderId, string mode = "preview", string? scope = null)
    {
        if (labOrderId <= 0) return BadRequest(new { message = "Valid LabOrderId is required." });

        // "approved" prints only the approved tests of a partly approved bill (a clean, final-looking copy);
        // "pending" prints the validated-but-unapproved ones; the default keeps the whole printable report.
        scope = LabReportPrintBuilder.NormalizeScope(scope);

        var isPreview = string.Equals(mode, "preview", StringComparison.OrdinalIgnoreCase);
        var isDownload = string.Equals(mode, "download", StringComparison.OrdinalIgnoreCase);

        try
        {
            var vm = await reportPdfService.BuildAsync(labOrderId, User, scope);
            if (vm == null)
                return NotFound(new { message = "Lab report details not found." });

            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
            var balanceDue = detail?.BalanceDue ?? 0m;
            if (balanceDue > 0)
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
                    $"Lab report printed from the Report Dispatch dashboard "
                    + $"({(vm.IsDuplicate ? $"duplicate copy, print #{vm.PrintSequence}" : "original copy")}"
                    + $"{(scope == LabReportPrintBuilder.ScopeApproved ? ", approved tests only" : "")}"
                    + $"{(scope == LabReportPrintBuilder.ScopePending ? $", {LabReportPdfService.PendingCopyMarker}" : "")}).",
                    vm.PrintSequence);

            var safeBill = new string((vm.BillNo ?? $"Order{labOrderId}").Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
            var fileName = $"LabReport_{safeBill}{(vm.ShowNotApprovedWatermark ? "_NOT-APPROVED" : "")}{(vm.IsDuplicate ? "_DUPLICATE" : "")}.pdf";

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
