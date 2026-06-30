using System.Net;
using System.Net.Mail;
using EMR.Web.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class EmailService(ApplicationDbContext dbContext, IDataProtectionProvider dataProtectionProvider) : IEmailService
{
    private const string ProtectorPurpose = "SmtpPassword.v1";

    public async Task<(bool Success, string Message)> SendTestEmailAsync(
        int configId, string recipientEmail, string subject, string body)
    {
        var config = await dbContext.SmtpEmailConfigurations.FindAsync(configId);
        if (config is null)
            return (false, "SMTP configuration not found.");

        try
        {
            var protector = dataProtectionProvider.CreateProtector(ProtectorPurpose);
            var decryptedPassword = protector.Unprotect(config.PasswordEncrypted);

            await SendViaSmtpAsync(config.SmtpHost, config.SmtpPort, config.UseSsl,
                config.SenderEmail, config.SenderDisplayName ?? config.SenderEmail,
                config.Username, decryptedPassword,
                recipientEmail, subject, body);

            // Update last test result
            config.LastTestedDate = DateTime.Now;
            config.LastTestResult = "Success";
            
            // Log success
            dbContext.EmailLogs.Add(new EmailLog
            {
                BranchId = config.BranchId,
                ConfigId = config.Id,
                RecipientEmail = recipientEmail,
                Subject = subject,
                SentDate = DateTime.Now,
                Status = "Success"
            });
            
            await dbContext.SaveChangesAsync();

            return (true, "Test email sent successfully!");
        }
        catch (Exception ex)
        {
            // Update last test result with error
            config.LastTestedDate = DateTime.Now;
            config.LastTestResult = $"Failed: {ex.Message}";
            
            // Log failure
            dbContext.EmailLogs.Add(new EmailLog
            {
                BranchId = config.BranchId,
                ConfigId = config.Id,
                RecipientEmail = recipientEmail,
                Subject = subject,
                SentDate = DateTime.Now,
                Status = "Failed",
                ErrorMessage = ex.Message
            });
            
            await dbContext.SaveChangesAsync();

            return (false, $"Failed to send email: {ex.Message}");
        }
    }

    public async Task<(bool Success, string Message)> SendEmailAsync(
        int branchId, string recipientEmail, string subject, string htmlBody, IEnumerable<Attachment>? attachments = null)
    {
        var config = await dbContext.SmtpEmailConfigurations
            .Where(x => x.BranchId == branchId && x.IsActive && x.IsDefault)
            .FirstOrDefaultAsync();

        if (config is null)
        {
            // Fallback: any active config for this branch
            config = await dbContext.SmtpEmailConfigurations
                .Where(x => x.BranchId == branchId && x.IsActive)
                .FirstOrDefaultAsync();
        }

        if (config is null)
            return (false, "No active SMTP configuration found for this branch.");

        try
        {
            var protector = dataProtectionProvider.CreateProtector(ProtectorPurpose);
            var decryptedPassword = protector.Unprotect(config.PasswordEncrypted);

            await SendViaSmtpAsync(config.SmtpHost, config.SmtpPort, config.UseSsl,
                config.SenderEmail, config.SenderDisplayName ?? config.SenderEmail,
                config.Username, decryptedPassword,
                recipientEmail, subject, htmlBody, isHtml: true, attachments: attachments);

            dbContext.EmailLogs.Add(new EmailLog
            {
                BranchId = config.BranchId,
                ConfigId = config.Id,
                RecipientEmail = recipientEmail,
                Subject = subject,
                SentDate = DateTime.Now,
                Status = "Success"
            });
            await dbContext.SaveChangesAsync();

            return (true, "Email sent successfully.");
        }
        catch (Exception ex)
        {
            dbContext.EmailLogs.Add(new EmailLog
            {
                BranchId = config.BranchId,
                ConfigId = config.Id,
                RecipientEmail = recipientEmail,
                Subject = subject,
                SentDate = DateTime.Now,
                Status = "Failed",
                ErrorMessage = ex.Message
            });
            await dbContext.SaveChangesAsync();

            return (false, $"Failed to send email: {ex.Message}");
        }
    }

    /// <summary>Encrypts a plain-text password for storage.</summary>
    public string EncryptPassword(string plainPassword)
    {
        var protector = dataProtectionProvider.CreateProtector(ProtectorPurpose);
        return protector.Protect(plainPassword);
    }

    private static async Task SendViaSmtpAsync(
        string host, int port, bool useSsl,
        string fromEmail, string fromName,
        string username, string password,
        string toEmail, string subject, string body,
        bool isHtml = false, IEnumerable<Attachment>? attachments = null)
    {
        using var message = new MailMessage
        {
            From = new MailAddress(fromEmail, fromName),
            Subject = subject,
            Body = body,
            IsBodyHtml = isHtml
        };
        message.To.Add(new MailAddress(toEmail));

        if (attachments != null)
        {
            foreach (var attachment in attachments)
            {
                message.Attachments.Add(attachment);
            }
        }

        using var client = new SmtpClient(host, port);
        client.EnableSsl = useSsl;
        client.UseDefaultCredentials = false;
        client.Credentials = new NetworkCredential(username, password);
        client.DeliveryMethod = SmtpDeliveryMethod.Network;
        client.Timeout = 30000; // 30 seconds

        await client.SendMailAsync(message);
    }
}
