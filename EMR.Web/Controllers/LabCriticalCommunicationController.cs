using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Critical value communication (NABL; SQLScripts/2202), shared by the Pathologist Dashboard sign-off, Report Entry
/// approval and Reports > LAB > Critical &amp; Panic Value Register: the form lists the bill's Critical / Panic results
/// and records who was informed, how and when. Allowed by the CRITICAL_COMM control of any of those pages.
/// Who is asking and the branch always come from the login; the procedures check the branch.
/// </summary>
[Authorize]
public class LabCriticalCommunicationController(
    ILabCriticalApiClient api,
    ILabCriticalNotificationService notifications,
    IAuditLogService auditLog,
    ILogger<LabCriticalCommunicationController> logger) : Controller
{
    private static readonly string[] Contexts = ["SIGNOFF", "ENTRY", "REGISTER"];

    public class PendingRequest
    {
        public int LabOrderId { get; set; }
        public List<long>? SampleIds { get; set; }
        public string? Context { get; set; }
    }

    public class RecordRequest
    {
        public int LabOrderId { get; set; }
        public string? Source { get; set; }
        public List<LabCriticalRecordItemDto> Items { get; set; } = new();
    }

    private int CurrentBranchId() => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

    [HttpPost]
    [RequiresPermission("LAB.PATHOLOGISTDASHBOARD", "CRITICAL_COMM")]
    [RequiresPermission("LAB.LABREPORTING", "CRITICAL_COMM")]
    [RequiresPermission("LAB.MICROBIOLOGYREPORTING", "CRITICAL_COMM")]
    [RequiresPermission("REPORTS.LABCRITICAL", "CRITICAL_COMM")]
    public async Task<IActionResult> Pending([FromBody] PendingRequest request)
    {
        if (request == null || request.LabOrderId <= 0) return Json(new { success = false, message = "Lab order is required." });
        var context = (request.Context ?? "REGISTER").Trim().ToUpperInvariant();
        if (!Contexts.Contains(context)) return Json(new { success = false, message = "Unknown context." });

        try
        {
            var (json, error) = await api.GetPendingRawAsync(CurrentBranchId(), request.LabOrderId, request.SampleIds, context,
                User.GetUserId(), User.IsSuperAdmin());
            if (error != null) return Json(new { success = false, message = error });
            return Content("{\"success\":true,\"data\":" + json + "}", "application/json");
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
    }

    [HttpPost]
    [RequiresPermission("LAB.PATHOLOGISTDASHBOARD", "CRITICAL_COMM")]
    [RequiresPermission("LAB.LABREPORTING", "CRITICAL_COMM")]
    [RequiresPermission("LAB.MICROBIOLOGYREPORTING", "CRITICAL_COMM")]
    [RequiresPermission("REPORTS.LABCRITICAL", "CRITICAL_COMM")]
    public async Task<IActionResult> Record([FromBody] RecordRequest request)
    {
        if (request == null || request.LabOrderId <= 0 || request.Items.Count == 0)
            return Json(new { success = false, message = "Nothing to record." });
        var source = (request.Source ?? "REGISTER").Trim().ToUpperInvariant();
        if (!Contexts.Contains(source)) source = "REGISTER";

        var branchId = CurrentBranchId();
        var userId = User.GetUserId();
        List<LabCriticalRecordedDto>? rows;
        string? error;
        try
        {
            (rows, error) = await api.RecordAsync(new LabCriticalRecordRequestDto
            {
                BranchId = branchId,
                LabOrderId = request.LabOrderId,
                Source = source,
                UserId = userId,
                IsSuperAdmin = User.IsSuperAdmin(),
                Items = request.Items
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The reporting service is unreachable. Please try again." });
        }
        if (error != null || rows == null) return Json(new { success = false, message = error ?? "Not saved. Please try again." });

        // WhatsApp / email chosen to be sent from the application: in the background, existing branch configuration
        var queued = rows.Where(r => r.MessageStatus == "QUEUED").Select(r => r.CommunicationId).ToList();
        if (queued.Count > 0) notifications.QueueSend(queued);

        try
        {
            foreach (var r in rows)
            {
                await auditLog.LogActivityAsync(
                    eventType: "Lab Reporting",
                    actionName: r.Outcome == "INFORMED" ? "LAB.CriticalValueInformed" : "LAB.CriticalValueAttempted",
                    description: $"{(r.Severity == "PANIC" ? "Panic" : "Critical")} value {r.TestName} {r.ResultValue} {r.Unit}: "
                                 + (r.Outcome == "INFORMED" ? "informed" : "could not reach")
                                 + $" {r.InformedName} ({r.InformedRole}) by {r.Mode} at {r.InformedOn:dd MMM yyyy, hh:mm tt}"
                                 + (r.CorrectsId.HasValue ? $" (corrects record {r.CorrectsId})" : "")
                                 + (r.MessageStatus == "QUEUED" ? "; message sent from the application" : ""),
                    userId: userId,
                    branchId: branchId,
                    moduleCode: "LAB",
                    referenceId: request.LabOrderId,
                    metadata: new { r.CommunicationId, r.SampleId, r.TestName, r.ResultValue, r.Unit, r.Severity, r.Outcome, r.InformedName,
                                    r.InformedRole, r.ContactNo, r.Mode, r.InformedOn, r.ReadBack, r.Remarks, r.CorrectsId, r.MessageStatus, Source = source });
            }
        }
        catch (Exception ex) { logger.LogWarning(ex, "[LAB-CRITICAL] Audit entry failed for LabOrderId {LabOrderId}", request.LabOrderId); }

        var informed = rows.Count(r => r.Outcome == "INFORMED");
        var message = informed == rows.Count
            ? $"Critical value communication recorded for {rows.Count} result(s)."
            : $"Recorded: {informed} informed, {rows.Count - informed} attempted.";
        if (queued.Count > 0) message += " The message is being sent; its delivery shows in the Critical & Panic Value Register.";
        return Json(new { success = true, message, rows });
    }
}
