using System.Net;
using System.Net.Mail;
using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>One send attempt on one channel, as kept in CertificateNotificationLog.</summary>
public class CertificateNotificationRow
{
    public string Channel { get; set; } = "";
    public string? Recipient { get; set; }
    public string Status { get; set; } = "";
    public string? Message { get; set; }
    public DateTime SentOn { get; set; }
    public string? SentByName { get; set; }
}

/// <summary>
/// OPD > Certificates (SQLScripts/2342): when Hospital Settings > OPD Configuration > "Notification Required for Issue
/// Certificate" is Yes, an issued certificate is sent to the patient as a PDF by WhatsApp (branch WhatsApp configuration)
/// and e-mail (branch SMTP configuration), with the QR verify link. Every attempt is logged per channel.
/// Sending runs in the background, so a slow or failing send never holds up issuing.
/// </summary>
public interface ICertificateNotificationService
{
    /// <summary>Hospital Settings switch of the branch.</summary>
    Task<bool> IsEnabledAsync(int branchId);

    /// <summary>Queues the send when the switch is on; returns whether it was queued.</summary>
    Task<bool> QueueOnIssueAsync(int branchId, int certificateId, int? userId, string baseUrl);

    /// <summary>Sends now on both channels and logs the outcome.</summary>
    Task<List<CertificateNotificationRow>> SendAsync(int branchId, int certificateId, int? userId, string baseUrl);

    Task<List<CertificateNotificationRow>> GetLogAsync(int certificateId);
}

public class CertificateNotificationService(
    IServiceScopeFactory scopeFactory,
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    ICertificateService certificates,
    IWhatsAppService whatsAppService,
    IEmailService emailService,
    ILabReportPdfService pdfService,
    ILogger<CertificateNotificationService> logger) : ICertificateNotificationService
{
    public async Task<bool> IsEnabledAsync(int branchId) =>
        await dbContext.HospitalSettings.AsNoTracking()
            .Where(h => h.BranchId == branchId)
            .Select(h => (bool?)h.OpdCertificateNotificationRequired)
            .FirstOrDefaultAsync() ?? false;

    public async Task<bool> QueueOnIssueAsync(int branchId, int certificateId, int? userId, string baseUrl)
    {
        if (!await IsEnabledAsync(branchId)) return false;
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                await scope.ServiceProvider.GetRequiredService<ICertificateNotificationService>().SendAsync(branchId, certificateId, userId, baseUrl);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[CERT-NOTIF] Unexpected error for CertificateId {Id}", certificateId);
            }
        });
        return true;
    }

    public async Task<List<CertificateNotificationRow>> SendAsync(int branchId, int certificateId, int? userId, string baseUrl)
    {
        var outcomes = new List<CertificateNotificationRow>();
        var m = await certificates.GetPrintModelAsync(branchId, certificateId);
        if (m == null || m.Certificate.Status != "I")
        {
            outcomes.Add(new() { Channel = "Certificate", Status = "Skipped", Message = "Only an issued certificate is sent." });
            return outcomes;
        }
        if (m.Certificate.VerifyToken is { Length: > 0 } token) m.VerifyUrl = $"{baseUrl.TrimEnd('/')}/verify/certificate/{token}";

        byte[] pdf;
        try
        {
            pdf = CertificatePdfDocument.Generate(m, new CertificatePdfImages
            {
                Logo = pdfService.LoadLogo(m.LogoPath),
                Photo = m.Certificate.TypeCode is "FIT" or "DIS" ? pdfService.LoadLogo(m.Patient.PhotoPath) : null,
                Signature = pdfService.LoadLogo(m.Doctor?.SignaturePath),
                Stamp = pdfService.LoadLogo(m.Doctor?.StampPath)
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[CERT-NOTIF] PDF failed for CertificateId {Id}", certificateId);
            await LogAsync(certificateId, branchId, "WhatsApp", m.Patient.PhoneNumber, "Failed", "The certificate PDF could not be generated.", userId, outcomes);
            await LogAsync(certificateId, branchId, "Email", m.Patient.EmailId, "Failed", "The certificate PDF could not be generated.", userId, outcomes);
            return outcomes;
        }

        var c = m.Certificate;
        var hospital = string.IsNullOrWhiteSpace(m.HospitalName) ? "our hospital" : m.HospitalName!;
        var patientName = $"{m.Patient.Salutation} {m.Patient.FullName}".Trim();
        var message = $"Dear {patientName}, your {m.Type.TypeName} No. {c.CertificateNo} dated {c.IssueDate:dd MMM yyyy}"
                    + (m.Doctor?.DoctorName is { Length: > 0 } dn ? $", signed by {dn}" : "")
                    + $", issued by {hospital}, is attached."
                    + (m.VerifyUrl != null ? $" It can be verified at {m.VerifyUrl}" : "")
                    + " Thank you.";
        var fileName = $"Certificate_{(c.CertificateNo ?? c.CertificateId.ToString()).Replace('/', '-')}.pdf";

        await SendWhatsAppAsync(m, branchId, userId, pdf, message, fileName, outcomes);
        await SendEmailAsync(m, branchId, userId, pdf, message, fileName, hospital, outcomes);
        return outcomes;
    }

    private async Task SendWhatsAppAsync(CertificatePrintModel m, int branchId, int? userId, byte[] pdf, string message, string fileName, List<CertificateNotificationRow> outcomes)
    {
        const string channel = "WhatsApp";
        var phone = m.Patient.PhoneNumber?.Trim();
        var id = m.Certificate.CertificateId;
        try
        {
            if (string.IsNullOrWhiteSpace(phone)) { await LogAsync(id, branchId, channel, null, "Skipped", "The patient has no mobile number.", userId, outcomes); return; }
            var config = await whatsAppService.GetActiveConfigAsync(branchId);
            if (config == null || !config.IsEnabled) { await LogAsync(id, branchId, channel, phone, "Skipped", "WhatsApp is not configured or is switched off for this branch.", userId, outcomes); return; }

            var documentUrl = await whatsAppService.UploadMediaAsync(pdf, "application/pdf", branchId);
            if (string.IsNullOrWhiteSpace(documentUrl)) { await LogAsync(id, branchId, channel, phone, "Failed", "The certificate PDF could not be uploaded to WhatsApp.", userId, outcomes); return; }

            var result = await whatsAppService.SendTextMessageAsync(phone, message, branchId, "CERT", id, documentUrl, fileName);
            if (result.Success) await LogAsync(id, branchId, channel, phone, "Sent", $"Sent to {phone}.", userId, outcomes);
            else await LogAsync(id, branchId, channel, phone, "Failed", string.IsNullOrWhiteSpace(result.ErrorMessage) ? "WhatsApp did not accept the message." : result.ErrorMessage!, userId, outcomes);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[CERT-NOTIF] WhatsApp failed for CertificateId {Id}", id);
            await LogAsync(id, branchId, channel, phone, "Failed", "WhatsApp send failed.", userId, outcomes);
        }
    }

    private async Task SendEmailAsync(CertificatePrintModel m, int branchId, int? userId, byte[] pdf, string message, string fileName, string hospital, List<CertificateNotificationRow> outcomes)
    {
        const string channel = "Email";
        var email = m.Patient.EmailId?.Trim();
        var c = m.Certificate;
        try
        {
            if (string.IsNullOrWhiteSpace(email)) { await LogAsync(c.CertificateId, branchId, channel, null, "Skipped", "The patient has no e-mail address.", userId, outcomes); return; }

            var details = new List<(string, string)>
            {
                ("Certificate No", WebUtility.HtmlEncode(c.CertificateNo ?? "")),
                ("Certificate", WebUtility.HtmlEncode(m.Type.TypeName)),
                ("Date of issue", c.IssueDate?.ToString("dd MMM yyyy") ?? "")
            };
            if (m.Doctor?.DoctorName is { Length: > 0 } dn) details.Add(("Signed by", WebUtility.HtmlEncode(dn)));
            var body = EmailLayout.Wrap(
                EmailLayout.P(WebUtility.HtmlEncode(message))
                + EmailLayout.Details(details.ToArray())
                + EmailLayout.P("Your certificate is attached to this e-mail as a PDF. Scan its QR code to check that it is genuine.", muted: true),
                heading: m.Type.TypeName,
                organisation: hospital);

            using var stream = new MemoryStream(pdf);
            using var attachment = new Attachment(stream, fileName, "application/pdf");
            var (success, text) = await emailService.SendEmailAsync(branchId, email, $"Your {m.Type.TypeName} {c.CertificateNo} - {hospital}", body, [attachment]);
            if (success) await LogAsync(c.CertificateId, branchId, channel, email, "Sent", $"Sent to {email}.", userId, outcomes);
            else await LogAsync(c.CertificateId, branchId, channel, email,
                text.Contains("No active SMTP", StringComparison.OrdinalIgnoreCase) ? "Skipped" : "Failed", text, userId, outcomes);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[CERT-NOTIF] E-mail failed for CertificateId {Id}", c.CertificateId);
            await LogAsync(c.CertificateId, branchId, channel, email, "Failed", "E-mail send failed.", userId, outcomes);
        }
    }

    private async Task LogAsync(int certificateId, int branchId, string channel, string? recipient, string status, string message, int? userId, List<CertificateNotificationRow> outcomes)
    {
        var msg = message.Length > 500 ? message[..500] : message;
        outcomes.Add(new() { Channel = channel, Recipient = recipient, Status = status, Message = msg, SentOn = DateTime.Now });
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync(@"INSERT dbo.CertificateNotificationLog (CertificateId, BranchId, Channel, Recipient, Status, Message, SentBy)
                VALUES (@certificateId, @branchId, @channel, @recipient, @status, @msg, @userId)",
                new { certificateId, branchId, channel, recipient, status, msg, userId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[CERT-NOTIF] Could not log {Channel} {Status} for CertificateId {Id}", channel, status, certificateId);
        }
    }

    public async Task<List<CertificateNotificationRow>> GetLogAsync(int certificateId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<CertificateNotificationRow>(@"
            SELECT TOP 20 l.Channel, l.Recipient, l.Status, l.Message, l.SentOn, u.FullName AS SentByName
              FROM dbo.CertificateNotificationLog l
              LEFT JOIN dbo.Users u ON u.Id = l.SentBy
             WHERE l.CertificateId = @certificateId
             ORDER BY l.SentOn DESC, l.LogId DESC", new { certificateId })).ToList();
    }
}
