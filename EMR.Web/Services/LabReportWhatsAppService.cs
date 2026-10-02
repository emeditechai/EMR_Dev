using System.Data;
using System.Security.Claims;
using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// WhatsAppConfig > Notification Trigger Settings > "B2C Approved Report Notification": once every reportable
/// test of a bill is approved AND the bill due is fully cleared, a patient is sent a WhatsApp message with the
/// approved report PDF attached.
/// For a B2B order, this only fires when the booking Franchise's "Notification Required" flag (Master > Franchise
/// Setup) is on - a franchise with it off is expected to hand the report to its patient itself. B2C is unaffected.
/// Triggered after a LAB Report / Image Report approval and after a LAB payment that clears the due.
/// Runs in the background, mirroring ILabReportEmailService, so a slow/failing WhatsApp send never blocks the approval.
/// </summary>
public interface ILabReportWhatsAppService
{
    /// <summary>Queues the check-and-send for this bill; returns immediately.</summary>
    void QueueIfFinal(int labOrderId, ClaimsPrincipal user, string trigger);

    /// <summary>Checks the bill and sends the WhatsApp message now. Returns the outcome for logging / tests.</summary>
    Task<LabReportWhatsAppOutcome> SendIfFinalAsync(int labOrderId, ClaimsPrincipal user, string trigger);
}

public record LabReportWhatsAppOutcome(string Status, string Message);

public class LabReportWhatsAppService(
    IServiceScopeFactory scopeFactory,
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    ILabReportingApiClient labReportingApiClient,
    ILabReportPdfService reportPdfService,
    IWhatsAppService whatsAppService,
    IAuditLogService auditLogService,
    ILogger<LabReportWhatsAppService> logger) : ILabReportWhatsAppService
{
    private sealed class WhatsAppState
    {
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public string? PatientName { get; set; }
        public string? PatientPhone { get; set; }
        public bool IsB2B { get; set; }
        public bool NotificationAllowed { get; set; }
        public int TotalTests { get; set; }
        public int ApprovedTests { get; set; }
        public bool IsFinal { get; set; }
        public DateTime? FinalApprovedOn { get; set; }
    }

    private sealed class Claim
    {
        public int? LabReportWhatsAppLogId { get; set; }
        public bool Proceed { get; set; }
        public bool IsRevised { get; set; }
    }

    public void QueueIfFinal(int labOrderId, ClaimsPrincipal user, string trigger)
    {
        if (labOrderId <= 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var svc = scope.ServiceProvider.GetRequiredService<ILabReportWhatsAppService>();
                await svc.SendIfFinalAsync(labOrderId, user, trigger);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[LAB-REPORT-WHATSAPP] Unexpected error for LabOrderId {LabOrderId}", labOrderId);
            }
        });
    }

    public async Task<LabReportWhatsAppOutcome> SendIfFinalAsync(int labOrderId, ClaimsPrincipal user, string trigger)
    {
        WhatsAppState? state;
        using (var con = db.CreateConnection())
        {
            state = await con.QueryFirstOrDefaultAsync<WhatsAppState>(
                "dbo.usp_LabReportWhatsApp_GetState", new { LabOrderId = labOrderId }, commandType: CommandType.StoredProcedure);
        }

        if (state == null) return new("NotFound", "Lab order not found.");

        // B2B Franchise gate: a franchise with "Notification Required" switched off never has its
        // patients WhatsApp'd the report - the franchise handles delivery to the patient instead.
        if (state.IsB2B && !state.NotificationAllowed)
            return new("NotApplicable", "Franchise notification is switched off for this B2B order.");

        var config = await whatsAppService.GetActiveConfigAsync(state.BranchId);
        if (config == null || !config.IsEnabled || !config.LabReportApprovedNotificationEnabled)
            return new("Disabled", "B2C approved report WhatsApp notification is switched off for this branch.");

        if (!state.IsFinal || state.FinalApprovedOn == null)
            return new("NotFinal", $"{state.ApprovedTests} of {state.TotalTests} test(s) approved.");

        var phone = state.PatientPhone?.Trim();
        var claim = await ClaimAsync(state, phone, trigger, user);
        if (claim == null || !claim.Proceed) return new("AlreadyHandled", "This final report was already WhatsApp'd (or is being sent).");
        var logId = claim.LabReportWhatsAppLogId!.Value;

        try
        {
            if (string.IsNullOrWhiteSpace(phone))
                return await FinishAsync(state, logId, "Skipped", "Patient has no phone number on file.", phone, claim.IsRevised, user, trigger);

            // Requested validation: the report is handed over via WhatsApp only once the bill due is fully cleared.
            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, state.BranchId);
            if (detail == null)
                return await FinishAsync(state, logId, "Failed", "Report details could not be loaded.", phone, claim.IsRevised, user, trigger);
            if (detail.BalanceDue > 0)
                return await FinishAsync(state, logId, "Skipped",
                    $"Outstanding due of Rs. {detail.BalanceDue:N2} - the report will be WhatsApp'd once the bill is fully paid.",
                    phone, claim.IsRevised, user, trigger);

            // One PDF per report of the bill: the Lab Report and/or the Microbiology Report (Reporting Type Template).
            var reports = new List<(string Type, EMR.Web.Models.ViewModels.LabReportPrintViewModel Vm, byte[] Pdf)>();
            foreach (var type in new[] { LabReportTypes.Numeric, LabReportTypes.Template })
            {
                var rvm = await reportPdfService.BuildAsync(labOrderId, user, LabReportPrintBuilder.ScopeApproved, type);
                if (rvm == null || rvm.IncludedTestCount == 0) continue;
                rvm.PrintSequence = 1;   // the patient's copy is an original, never "DUPLICATE"
                reports.Add((type, rvm, LabReportPdfDocument.Generate(rvm, reportPdfService.LoadLogo(rvm.HospitalLogoPath))));
            }
            if (reports.Count == 0)
                return await FinishAsync(state, logId, "Failed", "The approved report could not be generated.", phone, claim.IsRevised, user, trigger);
            var vm = reports[0].Vm;

            var settings = await dbContext.HospitalSettings.AsNoTracking()
                .Where(s => s.BranchId == state.BranchId && s.IsActive)
                .OrderByDescending(s => s.Id)
                .FirstOrDefaultAsync();
            var hospitalName = string.IsNullOrWhiteSpace(settings?.HospitalName) ? vm.HospitalName : settings!.HospitalName!;

            var safeBill = new string((state.BillNo ?? $"Order{labOrderId}").Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
            var messageTemplate = string.IsNullOrWhiteSpace(config.LabReportApprovedMessageTemplate)
                ? "Dear {PatientName}, your report for Bill {BillNo} at {HospitalName} has been approved. Please find your report attached. Thank you for choosing us!"
                : config.LabReportApprovedMessageTemplate;

            var message = messageTemplate
                .Replace("{PatientName}", state.PatientName ?? string.Empty)
                .Replace("{HospitalName}", hospitalName)
                .Replace("{BillNo}", state.BillNo ?? string.Empty)
                .Replace("{TokenNo}", state.TokenNo ?? "—")
                .Trim();

            // A WhatsApp message carries one document: the first report goes with the configured message,
            // a second one (the Microbiology Report of a bill that has both) follows with a short caption.
            var errors = new List<string>();
            for (int i = 0; i < reports.Count; i++)
            {
                var (type, _, pdfBytes) = reports[i];
                string? documentUrl = null;
                string? fileName = null;
                try
                {
                    documentUrl = await whatsAppService.UploadMediaAsync(pdfBytes, "application/pdf", state.BranchId);
                    if (!string.IsNullOrWhiteSpace(documentUrl))
                        fileName = $"{LabReportTypes.FilePrefix(type)}_{safeBill}.pdf";
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "[LAB-REPORT-WHATSAPP] Error uploading report PDF for LabOrderId {Id}", labOrderId);
                }

                var text = i == 0 ? message : $"{LabReportTypes.Title(type)} for Bill {state.BillNo} - {hospitalName}.";
                var sendResult = await whatsAppService.SendTextMessageAsync(phone, text, state.BranchId, "LABREPORT", labOrderId, documentUrl, fileName);
                if (!sendResult.Success) errors.Add(sendResult.ErrorMessage ?? "WhatsApp send failed.");
            }

            return errors.Count == 0
                ? await FinishAsync(state, logId, "Sent", $"WhatsApp'd to {phone}{(reports.Count > 1 ? $" ({reports.Count} reports)" : "")}.", phone, claim.IsRevised, user, trigger)
                : await FinishAsync(state, logId, "Failed", string.Join(" | ", errors), phone, claim.IsRevised, user, trigger);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[LAB-REPORT-WHATSAPP] Failed for LabOrderId {LabOrderId}", labOrderId);
            return await FinishAsync(state, logId, "Failed", ex.Message, phone, claim.IsRevised, user, trigger);
        }
    }

    private async Task<Claim?> ClaimAsync(WhatsAppState state, string? phone, string trigger, ClaimsPrincipal user)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<Claim>(
            "dbo.usp_LabReportWhatsApp_Claim",
            new
            {
                state.LabOrderId,
                state.BranchId,
                state.BillNo,
                state.FinalApprovedOn,
                RecipientPhone = phone,
                TriggeredBy = trigger,
                UserId = user.GetUserId() is > 0 and var id ? (int?)id : null
            },
            commandType: CommandType.StoredProcedure);
    }

    private async Task<LabReportWhatsAppOutcome> FinishAsync(WhatsAppState state, int logId, string status, string message,
        string? phone, bool isRevised, ClaimsPrincipal user, string trigger)
    {
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_LabReportWhatsApp_Complete",
                new { LabReportWhatsAppLogId = logId, Status = status, Message = message },
                commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[LAB-REPORT-WHATSAPP] Could not record status {Status} for log {LogId}", status, logId);
        }

        try
        {
            var action = status switch { "Sent" => "LAB.ReportWhatsAppSent", "Skipped" => "LAB.ReportWhatsAppSkipped", _ => "LAB.ReportWhatsAppFailed" };
            var what = isRevised ? "Revised lab report" : "Lab report";
            var description = status switch
            {
                "Sent" => $"{what} sent to the patient via WhatsApp ({phone}) with the approved report PDF attached.",
                "Skipped" => $"{what} WhatsApp notification not sent: {message}",
                _ => $"{what} WhatsApp notification failed: {message}"
            };
            await auditLogService.LogActivityAsync(
                eventType: "Lab Reporting",
                actionName: action,
                description: description,
                userId: user.GetUserId() is > 0 and var uid ? uid : null,
                branchId: state.BranchId,
                moduleCode: "LAB",
                referenceNo: state.BillNo,
                referenceId: state.LabOrderId,
                metadata: new { state.LabOrderId, state.BillNo, Recipient = phone, Status = status, Trigger = trigger, IsRevised = isRevised });
        }
        catch { /* logging never fails the notification */ }

        logger.LogInformation("[LAB-REPORT-WHATSAPP] LabOrderId {LabOrderId}: {Status} - {Message}", state.LabOrderId, status, message);
        return new(status, message);
    }
}
