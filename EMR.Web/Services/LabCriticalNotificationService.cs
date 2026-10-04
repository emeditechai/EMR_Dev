using System.Data;
using System.Net;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>
/// Critical value communication sent from the application (SQLScripts/2202): a record saved with "send the message"
/// is QUEUED; this sends it in the background through the existing WhatsApp / SMTP configuration of the branch
/// (as ILabReportWhatsAppService / ILabReportEmailService do), one message per recipient listing all its results,
/// then marks it SENT - or FAILED, which turns the record into "Attempted" with the error.
/// </summary>
public interface ILabCriticalNotificationService
{
    /// <summary>Queues the send; returns immediately.</summary>
    void QueueSend(IReadOnlyCollection<long> communicationIds);

    Task SendAsync(IReadOnlyCollection<long> communicationIds);
}

public class LabCriticalNotificationService(
    IServiceScopeFactory scopeFactory,
    IDbConnectionFactory db,
    IWhatsAppService whatsAppService,
    IEmailService emailService,
    ILogger<LabCriticalNotificationService> logger) : ILabCriticalNotificationService
{
    private sealed class MessageRow
    {
        public long CommunicationId { get; set; }
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public string Mode { get; set; } = "";
        public string? ContactNo { get; set; }
        public string? InformedName { get; set; }
        public string? Severity { get; set; }
        public string? ResultValue { get; set; }
        public string? Unit { get; set; }
        public string? Threshold { get; set; }
        public string? TestName { get; set; }
        public string? ProfileName { get; set; }
        public string? BillNo { get; set; }
        public string? PatientName { get; set; }
        public string? PatientCode { get; set; }
        public string? LabName { get; set; }
        public string? LabPhone { get; set; }
        public string? RecordedBy { get; set; }
    }

    public void QueueSend(IReadOnlyCollection<long> communicationIds)
    {
        if (communicationIds.Count == 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                await scope.ServiceProvider.GetRequiredService<ILabCriticalNotificationService>().SendAsync(communicationIds);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[LAB-CRITICAL] Unexpected error sending critical value messages {Ids}", string.Join(",", communicationIds));
            }
        });
    }

    public async Task SendAsync(IReadOnlyCollection<long> communicationIds)
    {
        List<MessageRow> rows;
        using (var con = db.CreateConnection())
        {
            rows = (await con.QueryAsync<MessageRow>("dbo.usp_LabCritical_GetMessageData",
                new { CommunicationIds = string.Join(",", communicationIds) }, commandType: CommandType.StoredProcedure)).ToList();
        }

        // one message per recipient: all the results they were informed of, together
        foreach (var group in rows.GroupBy(r => (r.Mode, Contact: (r.ContactNo ?? "").Trim().ToLowerInvariant(), r.LabOrderId)))
        {
            var list = group.ToList();
            var first = list[0];
            var ids = list.Select(r => r.CommunicationId).ToList();
            string? error = null, reference = null;
            try
            {
                if (first.Mode == "WHATSAPP")
                {
                    var config = await whatsAppService.GetActiveConfigAsync(first.BranchId);
                    if (config == null || !config.IsEnabled || !config.LabNotificationEnabled)
                        error = "WhatsApp is not configured or LAB notifications are switched off for this branch.";
                    else
                    {
                        var result = await whatsAppService.SendTextMessageAsync(first.ContactNo ?? "", WhatsAppText(list), first.BranchId,
                            "LAB_CRITICAL", first.LabOrderId);
                        if (result.Success) reference = result.MsgId; else error = result.ErrorMessage ?? "WhatsApp send failed.";
                    }
                }
                else if (first.Mode == "EMAIL")
                {
                    var (ok, message) = await emailService.SendEmailAsync(first.BranchId, first.ContactNo ?? "",
                        $"Critical value alert - {first.PatientName} ({first.BillNo})", EmailHtml(list));
                    if (!ok) error = string.IsNullOrWhiteSpace(message) ? "Email send failed." : message;
                }
                else error = "Only WhatsApp messages and emails can be sent from the application.";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[LAB-CRITICAL] Send failed for {Ids}", string.Join(",", ids));
                error = ex.Message;
            }

            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_LabCritical_SetMessageStatus",
                new { CommunicationIds = string.Join(",", ids), Status = error == null ? "SENT" : "FAILED", MessageRef = reference, MessageError = error },
                commandType: CommandType.StoredProcedure);
            if (error != null)
                logger.LogWarning("[LAB-CRITICAL] {Mode} to {Contact} not sent for LabOrderId {LabOrderId}: {Error}", first.Mode, first.ContactNo, first.LabOrderId, error);
        }
    }

    private static string ResultLine(MessageRow r)
        => $"{r.TestName}{(string.IsNullOrWhiteSpace(r.ProfileName) ? "" : $" ({r.ProfileName})")}: {r.ResultValue} {r.Unit}".TrimEnd()
           + $" - {(r.Severity == "PANIC" ? "PANIC" : "CRITICAL")}{(string.IsNullOrWhiteSpace(r.Threshold) ? "" : $", limit {r.Threshold}")}";

    private static string WhatsAppText(List<MessageRow> list)
    {
        var f = list[0];
        var lines = new List<string>
        {
            $"*Critical value alert* - {f.LabName}",
            $"Dear {f.InformedName},",
            $"Patient: {f.PatientName} ({f.PatientCode}), Bill {f.BillNo}"
        };
        lines.AddRange(list.Select(r => "• " + ResultLine(r)));
        lines.Add(string.IsNullOrWhiteSpace(f.LabPhone)
            ? "Please contact the laboratory to acknowledge this result."
            : $"Please call the laboratory on {f.LabPhone} to acknowledge this result.");
        lines.Add($"- {f.RecordedBy}, {f.LabName}");
        return string.Join("\n", lines);
    }

    private static string EmailHtml(List<MessageRow> list)
    {
        static string E(string? v) => WebUtility.HtmlEncode(v ?? "");
        var f = list[0];
        var items = string.Join("", list.Select(r => $"<li style=\"margin:4px 0\"><b>{E(r.TestName)}</b>{(string.IsNullOrWhiteSpace(r.ProfileName) ? "" : $" ({E(r.ProfileName)})")}: "
            + $"<b style=\"color:#b91c1c\">{E(r.ResultValue)} {E(r.Unit)}</b> &ndash; {(r.Severity == "PANIC" ? "Panic" : "Critical")}"
            + $"{(string.IsNullOrWhiteSpace(r.Threshold) ? "" : $", limit {E(r.Threshold)}")}</li>"));
        return $"""
            <div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#111">
              <h2 style="color:#b91c1c;margin:0 0 12px">Critical value alert</h2>
              <p>Dear {E(f.InformedName)},</p>
              <p>The following result(s) of <b>{E(f.PatientName)}</b> ({E(f.PatientCode)}), bill <b>{E(f.BillNo)}</b>, crossed a critical threshold:</p>
              <ul>{items}</ul>
              <p>{(string.IsNullOrWhiteSpace(f.LabPhone) ? "Please contact the laboratory to acknowledge this result." : $"Please call the laboratory on <b>{E(f.LabPhone)}</b> to acknowledge this result.")}</p>
              <p style="color:#555">{E(f.RecordedBy)}<br>{E(f.LabName)}</p>
            </div>
            """;
    }
}
