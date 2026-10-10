using System.Net;
using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// OPD follow-up reminders (SQLScripts/2229). The doctor sets a Follow-Up Date in the EMR; when the branch has
/// Hospital Settings > OPD Configuration > "Follow up Notification Required" = Yes, the patient gets a reminder by
/// e-mail and WhatsApp (whichever the patient and the branch have) 7 days before the follow-up date, and again 1 day
/// before. Setting = No: nothing is sent.
///
/// Runs every 30 minutes between 08:00 and 20:00 (server time). Each reminder is claimed in the database before it is
/// sent (FollowUpReminder7SentOn / FollowUpReminder1SentOn), so it goes out once even if the job runs twice or on two
/// servers. The 7-day reminder is sent only when the follow-up was set at least 7 days ahead; if the job was not running
/// on that day it catches up until 2 days before. Changing the follow-up date in the EMR starts its reminders again.
/// </summary>
public sealed class FollowUpReminderService(IServiceScopeFactory scopeFactory, ILogger<FollowUpReminderService> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan FirstRunDelay = TimeSpan.FromMinutes(2);
    private const int SendFromHour = 8, SendUntilHour = 20;

    private sealed class DueReminder
    {
        public int ConsultationId { get; set; }
        public int OPDServiceId { get; set; }
        public DateTime FollowUpDate { get; set; }
        public int Kind { get; set; }                 // 7 = a week before, 1 = the day before
        public int BranchId { get; set; }
        public string? PatientName { get; set; }
        public string? PatientCode { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? DoctorName { get; set; }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(FirstRunDelay, stoppingToken); } catch (OperationCanceledException) { return; }
        while (!stoppingToken.IsCancellationRequested)
        {
            var hour = DateTime.Now.Hour;
            if (hour >= SendFromHour && hour < SendUntilHour)
            {
                try { await RunOnceAsync(stoppingToken); }
                catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogError(ex, "[FollowUp] Reminder run failed"); }
            }
            try { await Task.Delay(Interval, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Sends every reminder that is due now. Public for a manual run / test.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct = default)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<IDbConnectionFactory>();
        using var con = db.CreateConnection();

        var due = (await con.QueryAsync<DueReminder>(@"
            DECLARE @Today DATE = CAST(GETDATE() AS DATE);
            SELECT c.ConsultationId, c.OPDServiceId, CAST(c.FollowUpDate AS DATETIME) AS FollowUpDate,
                   CASE WHEN c.FollowUpReminder1SentOn IS NULL AND @Today = DATEADD(DAY, -1, c.FollowUpDate) THEN 1 ELSE 7 END AS Kind,
                   s.BranchId,
                   LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
                   p.PatientCode, p.PhoneNumber, p.EmailId,
                   LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName
            FROM dbo.EmrPatientConsultation c
            INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = c.OPDServiceId AND ISNULL(s.IsActive, 0) = 1
            INNER JOIN dbo.PatientMaster p ON p.PatientId = c.PatientId
            LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
            WHERE c.FollowUpDate IS NOT NULL AND c.FollowUpDate > @Today
              AND EXISTS (SELECT 1 FROM dbo.HospitalSettings hs
                          WHERE hs.BranchId = s.BranchId AND hs.IsActive = 1 AND hs.OpdFollowUpNotificationRequired = 1)
              AND (   (c.FollowUpReminder1SentOn IS NULL AND @Today = DATEADD(DAY, -1, c.FollowUpDate))
                   OR (c.FollowUpReminder7SentOn IS NULL
                       AND @Today >= DATEADD(DAY, -7, c.FollowUpDate) AND @Today < DATEADD(DAY, -1, c.FollowUpDate)
                       AND CAST(ISNULL(c.FollowUpSetOn, c.CreatedDate) AS DATE) <= DATEADD(DAY, -7, c.FollowUpDate)))")).ToList();
        if (due.Count == 0) return 0;

        var email = scope.ServiceProvider.GetRequiredService<IEmailService>();
        var whatsApp = scope.ServiceProvider.GetRequiredService<IWhatsAppService>();
        var ef = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
        var sent = 0;

        foreach (var r in due)
        {
            ct.ThrowIfCancellationRequested();

            // claim it first: whoever sets the column sends the reminder; nobody else will
            var column = r.Kind == 1 ? "FollowUpReminder1SentOn" : "FollowUpReminder7SentOn";
            var claimed = await con.ExecuteAsync($@"
                UPDATE dbo.EmrPatientConsultation SET {column} = GETDATE()
                WHERE ConsultationId = @Id AND {column} IS NULL AND FollowUpDate = @Date",
                new { Id = r.ConsultationId, Date = r.FollowUpDate.Date });
            if (claimed != 1) continue;

            var settings = await ef.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(s => s.BranchId == r.BranchId && s.IsActive, ct);
            var hospital = string.IsNullOrWhiteSpace(settings?.HospitalName) ? "the hospital" : settings!.HospitalName!.Trim();
            var contact = settings?.ContactNumber1;
            var when = r.Kind == 1 ? "tomorrow" : "in 7 days";
            var dateText = r.FollowUpDate.ToString("dddd, dd MMM yyyy");
            var name = string.IsNullOrWhiteSpace(r.PatientName) ? "Patient" : r.PatientName!.Trim();
            var doctor = string.IsNullOrWhiteSpace(r.DoctorName) ? "your doctor" : r.DoctorName!.Trim();

            var channels = new List<string>();
            if (!string.IsNullOrWhiteSpace(r.EmailId) && r.EmailId!.Contains('@'))
            {
                try
                {
                    var (ok, msg) = await email.SendEmailAsync(r.BranchId, r.EmailId.Trim(),
                        $"Follow-up reminder: {dateText} - {hospital}", EmailBody(name, doctor, hospital, contact, when, dateText, r.PatientCode));
                    channels.Add(ok ? "e-mail" : $"e-mail failed ({msg})");
                }
                catch (Exception ex) { channels.Add("e-mail failed"); logger.LogWarning(ex, "[FollowUp] e-mail for consultation {Id}", r.ConsultationId); }
            }
            if (!string.IsNullOrWhiteSpace(r.PhoneNumber))
            {
                try
                {
                    var text = $"Dear {name},\n\nThis is a reminder from {hospital}: your follow-up visit with {doctor} is {when}, on {dateText}."
                             + (string.IsNullOrWhiteSpace(r.PatientCode) ? "" : $"\nPatient ID: {r.PatientCode}")
                             + (string.IsNullOrWhiteSpace(contact) ? "" : $"\nTo book or change the visit, please call {contact}.")
                             + "\n\nThank you.";
                    var res = await whatsApp.SendTextMessageAsync(r.PhoneNumber!.Trim(), text, r.BranchId, "OPD_FOLLOWUP", r.ConsultationId);
                    channels.Add(res.Success ? "WhatsApp" : $"WhatsApp failed ({res.ErrorMessage})");
                }
                catch (Exception ex) { channels.Add("WhatsApp failed"); logger.LogWarning(ex, "[FollowUp] WhatsApp for consultation {Id}", r.ConsultationId); }
            }

            sent++;
            logger.LogInformation("[FollowUp] {Kind}-day reminder for consultation {Id} (follow-up {Date:yyyy-MM-dd}): {Channels}",
                r.Kind, r.ConsultationId, r.FollowUpDate, channels.Count > 0 ? string.Join(", ", channels) : "no e-mail or mobile on record");
        }
        return sent;
    }

    private static string EmailBody(string name, string doctor, string hospital, string? contact, string when, string dateText, string? patientCode)
    {
        static string H(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);
        return $@"<div style=""font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;max-width:560px"">
  <div style=""background:#1e3a8a;color:#fff;padding:14px 18px;border-radius:8px 8px 0 0;font-size:16px;font-weight:bold"">{H(hospital)}</div>
  <div style=""border:1px solid #e5e7eb;border-top:0;padding:18px;border-radius:0 0 8px 8px"">
    <p>Dear {H(name)},</p>
    <p>This is a friendly reminder that your <strong>follow-up visit</strong> with <strong>{H(doctor)}</strong> is <strong>{H(when)}</strong>.</p>
    <table style=""border-collapse:collapse;margin:12px 0"">
      <tr><td style=""padding:4px 12px 4px 0;color:#6b7280"">Date</td><td style=""padding:4px 0""><strong>{H(dateText)}</strong></td></tr>
      <tr><td style=""padding:4px 12px 4px 0;color:#6b7280"">Doctor</td><td style=""padding:4px 0"">{H(doctor)}</td></tr>
      {(string.IsNullOrWhiteSpace(patientCode) ? "" : $@"<tr><td style=""padding:4px 12px 4px 0;color:#6b7280"">Patient ID</td><td style=""padding:4px 0"">{H(patientCode)}</td></tr>")}
    </table>
    {(string.IsNullOrWhiteSpace(contact) ? "" : $"<p>To book or change the visit, please call <strong>{H(contact)}</strong>.</p>")}
    <p style=""color:#6b7280;font-size:12px;margin-top:18px"">This is an automated reminder from {H(hospital)}.</p>
  </div>
</div>";
    }
}
