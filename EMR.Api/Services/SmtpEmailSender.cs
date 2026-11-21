using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Common;
using Microsoft.AspNetCore.DataProtection;

namespace EMR.Api.Services;

/// <summary>An e-mail attachment: its name, type and bytes.</summary>
public sealed record EmailAttachment(string FileName, string ContentType, byte[] Bytes);

public interface ISmtpEmailSender
{
    /// <summary>
    /// Sends an e-mail with the branch's SMTP configuration (Utility > Email Configuration: the default one, else any active
    /// one) and records it in dbo.EmailLogs, as EMR.Web's EmailService does.
    /// </summary>
    Task<(bool Success, string Message)> SendAsync(int branchId, string recipientEmail, string subject, string htmlBody,
        IEnumerable<EmailAttachment>? attachments = null);
}

/// <summary>
/// EMR.Web keeps the SMTP password encrypted with its ASP.NET data protection key ring, which it stores in
/// dbo.DataProtectionKeys (application "EMR_Web_App"). This sender reads that key ring from the database (never writes
/// it) to decrypt the password, so EMR.Api sends with the same configuration.
/// </summary>
public sealed class SmtpEmailSender(IDbConnectionFactory db, ILogger<SmtpEmailSender> logger) : ISmtpEmailSender
{
    private const string ProtectorPurpose = "SmtpPassword.v1";   // EMR.Web EmailService

    private sealed class SmtpConfig
    {
        public int Id { get; set; }
        public int BranchId { get; set; }
        public string SmtpHost { get; set; } = "";
        public int SmtpPort { get; set; }
        public bool UseSsl { get; set; }
        public string SenderEmail { get; set; } = "";
        public string? SenderDisplayName { get; set; }
        public string Username { get; set; } = "";
        public string PasswordEncrypted { get; set; } = "";
    }

    public async Task<(bool Success, string Message)> SendAsync(int branchId, string recipientEmail, string subject, string htmlBody,
        IEnumerable<EmailAttachment>? attachments = null)
    {
        using var con = db.CreateConnection();
        var config = await con.QueryFirstOrDefaultAsync<SmtpConfig>(
            @"SELECT TOP 1 Id, BranchId, SmtpHost, SmtpPort, UseSsl, SenderEmail, SenderDisplayName, Username, PasswordEncrypted
                FROM dbo.SmtpEmailConfiguration WHERE BranchId = @branchId AND IsActive = 1
               ORDER BY CASE WHEN IsDefault = 1 THEN 0 ELSE 1 END, Id", new { branchId });
        if (config is null) return (false, "No active SMTP configuration found for this branch.");

        try
        {
            var password = WebKeyRing.Provider(db).CreateProtector(ProtectorPurpose).Unprotect(config.PasswordEncrypted);
            var message = new MimeKit.MimeMessage();
            message.From.Add(new MimeKit.MailboxAddress(config.SenderDisplayName ?? config.SenderEmail, config.SenderEmail));
            message.To.Add(new MimeKit.MailboxAddress("", recipientEmail));
            message.Subject = subject;
            var builder = new MimeKit.BodyBuilder { HtmlBody = EmailLayout.EnsureBranded(htmlBody) };
            foreach (var a in attachments ?? []) builder.Attachments.Add(a.FileName, a.Bytes, MimeKit.ContentType.Parse(a.ContentType));
            message.Body = builder.ToMessageBody();

            using var client = new MailKit.Net.Smtp.SmtpClient();
            client.ServerCertificateValidationCallback = (_, _, _, _) => true;
            await client.ConnectAsync(config.SmtpHost, config.SmtpPort,
                config.UseSsl ? MailKit.Security.SecureSocketOptions.SslOnConnect : MailKit.Security.SecureSocketOptions.Auto);
            if (!string.IsNullOrEmpty(config.Username)) await client.AuthenticateAsync(config.Username, password);
            await client.SendAsync(message);
            await client.DisconnectAsync(true);

            await LogAsync(con, config, recipientEmail, subject, "Success", null);
            return (true, "Email sent successfully.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[EMAIL] Not sent for branch {BranchId}", branchId);
            await LogAsync(con, config, recipientEmail, subject, "Failed", ex.Message);
            return (false, $"Failed to send email: {ex.Message}");
        }
    }

    private async Task LogAsync(IDbConnection con, SmtpConfig config, string to, string subject, string status, string? error)
    {
        try
        {
            await con.ExecuteAsync(
                @"INSERT dbo.EmailLogs (BranchId, ConfigId, RecipientEmail, Subject, SentDate, Status, ErrorMessage)
                  VALUES (@BranchId, @ConfigId, @To, @Subject, GETDATE(), @Status, @Error)",
                new { config.BranchId, ConfigId = config.Id, To = to, Subject = subject, Status = status, Error = error });
        }
        catch (Exception ex) { logger.LogWarning(ex, "[EMAIL] Log not written"); }
    }
}
