namespace EMR.Web.Services;

public interface IEmailService
{
    /// <summary>
    /// Sends a test email using the specified SMTP configuration.
    /// Returns (success, message) tuple.
    /// </summary>
    Task<(bool Success, string Message)> SendTestEmailAsync(int configId, string recipientEmail, string subject, string body);

    /// <summary>
    /// Sends an email using the default SMTP configuration for the given branch.
    /// </summary>
    Task<(bool Success, string Message)> SendEmailAsync(int branchId, string recipientEmail, string subject, string htmlBody);
}
