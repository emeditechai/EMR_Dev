using System.Data;
using System.Net;
using System.Security.Claims;
using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Hospital Settings > LAB > "Email Notification to Patient (LAB Reports)": once every reportable test of a bill is
/// approved, the patient is emailed the final report (PDF attached) through the booking branch's SMTP configuration.
/// Triggered after an approval (Report Entry / Pathologist Dashboard) and after a LAB payment that clears the due.
/// Runs in the background, so a slow or failing mail server never delays or fails the approval / payment.
/// </summary>
public interface ILabReportEmailService
{
    /// <summary>Queues the check-and-send for this bill; returns immediately.</summary>
    void QueueIfFinal(int labOrderId, ClaimsPrincipal user, string trigger);

    /// <summary>Checks the bill and sends the report now. Returns the outcome for logging / tests.</summary>
    Task<LabReportEmailOutcome> SendIfFinalAsync(int labOrderId, ClaimsPrincipal user, string trigger);
}

public record LabReportEmailOutcome(string Status, string Message);

public static class LabReportEmailTriggers
{
    public const string EntryApproval = "EntryApproval";
    public const string PathologistApproval = "PathologistApproval";
    public const string PaymentCleared = "PaymentCleared";
}

public class LabReportEmailService(
    IServiceScopeFactory scopeFactory,
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    ILabReportingApiClient labReportingApiClient,
    ILabReportPdfService reportPdfService,
    IEmailService emailService,
    IAuditLogService auditLogService,
    ILogger<LabReportEmailService> logger) : ILabReportEmailService
{
    private sealed class EmailState
    {
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public string? PatientName { get; set; }
        public string? PatientEmail { get; set; }
        public int TotalTests { get; set; }
        public int ApprovedTests { get; set; }
        public bool IsFinal { get; set; }
        public DateTime? FinalApprovedOn { get; set; }
        public bool EmailEnabled { get; set; }
    }

    private sealed class Claim
    {
        public int? LabReportEmailLogId { get; set; }
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
                var svc = scope.ServiceProvider.GetRequiredService<ILabReportEmailService>();
                await svc.SendIfFinalAsync(labOrderId, user, trigger);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[LAB-REPORT-EMAIL] Unexpected error for LabOrderId {LabOrderId}", labOrderId);
            }
        });
    }

    public async Task<LabReportEmailOutcome> SendIfFinalAsync(int labOrderId, ClaimsPrincipal user, string trigger)
    {
        EmailState? state;
        using (var con = db.CreateConnection())
        {
            state = await con.QueryFirstOrDefaultAsync<EmailState>(
                "dbo.usp_LabReportEmail_GetState", new { LabOrderId = labOrderId }, commandType: CommandType.StoredProcedure);
        }

        // Nothing is recorded while the setting is off or the bill is not final yet - those are the normal cases.
        if (state == null) return new("NotFound", "Lab order not found.");
        if (!state.EmailEnabled) return new("Disabled", "Lab report email is switched off for this branch.");
        if (!state.IsFinal || state.FinalApprovedOn == null)
            return new("NotFinal", $"{state.ApprovedTests} of {state.TotalTests} test(s) approved.");

        var email = state.PatientEmail?.Trim();
        var claim = await ClaimAsync(state, email, trigger, user);
        if (claim == null || !claim.Proceed) return new("AlreadyHandled", "This final report was already emailed (or is being emailed).");
        var logId = claim.LabReportEmailLogId!.Value;

        try
        {
            if (!IsValidEmail(email))
                return await FinishAsync(state, logId, "Skipped",
                    string.IsNullOrWhiteSpace(email) ? "Patient has no email address." : $"Patient email '{email}' is not valid.",
                    email, claim.IsRevised, user, trigger);

            // Same rule as the Report Dispatch print: no hand-over while a due is outstanding.
            // The payment that clears it triggers this again.
            var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
            if (detail == null)
                return await FinishAsync(state, logId, "Failed", "Report details could not be loaded.", email, claim.IsRevised, user, trigger);
            if (detail.BalanceDue > 0)
                return await FinishAsync(state, logId, "Skipped",
                    $"Outstanding due of Rs. {detail.BalanceDue:N2} - the report will be emailed once the bill is paid.",
                    email, claim.IsRevised, user, trigger);

            var vm = await reportPdfService.BuildAsync(labOrderId, user, LabReportPrintBuilder.ScopeApproved);
            if (vm == null || vm.IncludedTestCount == 0)
                return await FinishAsync(state, logId, "Failed", "The approved report could not be generated.", email, claim.IsRevised, user, trigger);
            vm.PrintSequence = 1;   // the patient's copy is an original, never "DUPLICATE"

            var pdf = LabReportPdfDocument.Generate(vm, reportPdfService.LoadLogo(vm.HospitalLogoPath));

            var settings = await dbContext.HospitalSettings.AsNoTracking()
                .Where(s => s.BranchId == state.BranchId && s.IsActive)
                .OrderByDescending(s => s.Id)
                .FirstOrDefaultAsync();

            var hospital = string.IsNullOrWhiteSpace(settings?.HospitalName) ? vm.HospitalName : settings!.HospitalName!;
            var tests = vm.Sections.SelectMany(s => s.Groups).SelectMany(g => g.Rows).Select(r => r.TestName)
                          .Where(n => !string.IsNullOrWhiteSpace(n)).Distinct().ToList();

            var subject = $"{(claim.IsRevised ? "Revised " : "")}Lab Report - {state.BillNo} | {hospital}";
            var body = BuildBody(state, hospital, settings, tests, claim.IsRevised);
            var safeBill = new string((state.BillNo ?? $"Order{labOrderId}").Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());

            using var stream = new MemoryStream(pdf);
            using var attachment = new System.Net.Mail.Attachment(stream, $"LabReport_{safeBill}.pdf", "application/pdf");
            var (ok, message) = await emailService.SendEmailAsync(state.BranchId, email!, subject, body, new[] { attachment });

            return ok
                ? await FinishAsync(state, logId, "Sent", $"Emailed to {email}.", email, claim.IsRevised, user, trigger)
                : await FinishAsync(state, logId, "Failed", message, email, claim.IsRevised, user, trigger);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[LAB-REPORT-EMAIL] Failed for LabOrderId {LabOrderId}", labOrderId);
            return await FinishAsync(state, logId, "Failed", ex.Message, email, claim.IsRevised, user, trigger);
        }
    }

    private async Task<Claim?> ClaimAsync(EmailState state, string? email, string trigger, ClaimsPrincipal user)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<Claim>(
            "dbo.usp_LabReportEmail_Claim",
            new
            {
                state.LabOrderId,
                state.BranchId,
                state.BillNo,
                state.FinalApprovedOn,
                RecipientEmail = email,
                TriggeredBy = trigger,
                UserId = user.GetUserId() is > 0 and var id ? (int?)id : null
            },
            commandType: CommandType.StoredProcedure);
    }

    private async Task<LabReportEmailOutcome> FinishAsync(EmailState state, int logId, string status, string message,
        string? email, bool isRevised, ClaimsPrincipal user, string trigger)
    {
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_LabReportEmail_Complete",
                new { LabReportEmailLogId = logId, Status = status, Message = message },
                commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[LAB-REPORT-EMAIL] Could not record status {Status} for log {LogId}", status, logId);
        }

        // The bill's activity trail shows what happened to the patient's copy.
        try
        {
            var action = status switch { "Sent" => "LAB.ReportEmailed", "Skipped" => "LAB.ReportEmailSkipped", _ => "LAB.ReportEmailFailed" };
            var what = isRevised ? "Revised lab report" : "Lab report";
            var description = status switch
            {
                "Sent" => $"{what} emailed to the patient ({email}) with the approved report PDF attached.",
                "Skipped" => $"{what} email not sent: {message}",
                _ => $"{what} email failed: {message}"
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
                metadata: new { state.LabOrderId, state.BillNo, Recipient = email, Status = status, Trigger = trigger, IsRevised = isRevised });
        }
        catch { /* logging never fails the notification */ }

        logger.LogInformation("[LAB-REPORT-EMAIL] LabOrderId {LabOrderId}: {Status} - {Message}", state.LabOrderId, status, message);
        return new(status, message);
    }

    private static bool IsValidEmail(string? email)
    {
        if (string.IsNullOrWhiteSpace(email)) return false;
        try { return new System.Net.Mail.MailAddress(email).Address == email; }
        catch { return false; }
    }

    private static string BuildBody(EmailState state, string hospital, Models.Entities.HospitalSettings? s, List<string> tests, bool isRevised)
    {
        static string H(string? v) => WebUtility.HtmlEncode(v ?? string.Empty);

        var testRows = string.Join("", tests.Select(t =>
            $"<tr><td style=\"padding:6px 0;border-bottom:1px solid #eef2f6;color:#1f2937;font-size:14px;\">&#10003;&nbsp; {H(t)}</td></tr>"));
        var contact = string.Join(" &nbsp;|&nbsp; ", new[]
        {
            string.IsNullOrWhiteSpace(s?.ContactNumber1) ? null : $"Phone: {H(s!.ContactNumber1)}",
            string.IsNullOrWhiteSpace(s?.EmailAddress) ? null : $"Email: {H(s!.EmailAddress)}",
            string.IsNullOrWhiteSpace(s?.Website) ? null : $"<a href=\"{H(s!.Website)}\" style=\"color:#0f766e;\">{H(s!.Website)}</a>"
        }.Where(x => x != null));
        var revisedNote = isRevised
            ? "<p style=\"margin:0 0 16px;padding:10px 14px;background:#fffbeb;border-left:4px solid #f59e0b;color:#92400e;font-size:13px;\">This is a <strong>revised</strong> report and replaces the one sent earlier for this bill.</p>"
            : "";

        return $@"<!DOCTYPE html>
<html><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1""><title>Your Lab Report</title></head>
<body style=""margin:0;padding:0;background:#f1f5f9;font-family:'Segoe UI',Arial,Helvetica,sans-serif;"">
<table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:#f1f5f9;padding:24px 12px;"">
<tr><td align=""center"">
<table role=""presentation"" width=""600"" cellpadding=""0"" cellspacing=""0"" style=""max-width:600px;width:100%;background:#ffffff;border-radius:10px;overflow:hidden;box-shadow:0 2px 8px rgba(15,23,42,.08);"">
  <tr><td style=""background:#0f766e;padding:22px 28px;color:#ffffff;"">
    <div style=""font-size:20px;font-weight:700;"">{H(hospital)}</div>
    <div style=""font-size:13px;opacity:.9;margin-top:2px;"">Department of Laboratory Medicine</div>
  </td></tr>
  <tr><td style=""padding:28px;"">
    <p style=""margin:0 0 14px;font-size:16px;color:#0f172a;"">Dear <strong>{H(state.PatientName)}</strong>,</p>
    {revisedNote}
    <p style=""margin:0 0 16px;font-size:14px;line-height:1.6;color:#334155;"">Your laboratory test report is ready. It has been reviewed and approved, and a copy is attached to this email as a PDF document.</p>
    <table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;margin:0 0 18px;"">
      <tr><td style=""padding:14px 18px;font-size:14px;color:#334155;line-height:1.8;"">
        <strong>Bill No:</strong> {H(state.BillNo)}<br>
        {(string.IsNullOrWhiteSpace(state.TokenNo) ? "" : $"<strong>Token No:</strong> {H(state.TokenNo)}<br>")}
        <strong>Report approved on:</strong> {state.FinalApprovedOn:dd MMM yyyy, hh:mm tt}<br>
        <strong>Tests reported:</strong> {tests.Count}
      </td></tr>
    </table>
    {(tests.Count == 0 ? "" : $@"<div style=""font-size:12px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;color:#64748b;margin:0 0 4px;"">Investigations</div>
    <table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""margin:0 0 18px;"">{testRows}</table>")}
    <p style=""margin:0 0 16px;font-size:14px;line-height:1.6;color:#334155;"">Please share this report with your doctor, who will interpret the results in the context of your health. If you have any questions, feel free to contact us.</p>
    <p style=""margin:0;font-size:14px;color:#334155;"">Wishing you good health,<br><strong>{H(hospital)}</strong></p>
  </td></tr>
  <tr><td style=""background:#f8fafc;border-top:1px solid #e2e8f0;padding:16px 28px;font-size:12px;color:#64748b;line-height:1.6;"">
    {(string.IsNullOrWhiteSpace(s?.Address) ? "" : $"{H(s!.Address)}<br>")}
    {(contact.Length == 0 ? "" : contact + "<br>")}
    <span style=""color:#94a3b8;"">This email and its attachment contain confidential medical information meant only for the addressee. If you received it by mistake, please delete it and let us know. This is an automated message - please do not reply to this email.</span>
  </td></tr>
</table>
</td></tr></table>
</body></html>";
    }
}
