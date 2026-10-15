namespace EMR.Web.Services;

/// <summary>The "your login details" mail sent to a new franchise / corporate login - when the record is saved, or,
/// for a record under approval, when it is approved.</summary>
public interface ILoginCredentialsMailer
{
    /// <summary>Sent with the branch's mail settings, else those of <paramref name="fallbackBranchId"/>
    /// (a new branch often has no mail settings of its own).</summary>
    Task<(bool Sent, string Reason)> SendAsync(int branchId, int? fallbackBranchId, string name, string email, string password, string defaultBaseUrl);
}

public class LoginCredentialsMailer(IEmailService emailService, ILogger<LoginCredentialsMailer> logger) : ILoginCredentialsMailer
{
    public const string DefaultPassword = "Welcome@123";

    public async Task<(bool Sent, string Reason)> SendAsync(int branchId, int? fallbackBranchId, string name, string email, string password, string defaultBaseUrl)
    {
        try
        {
            var baseUrl = await emailService.GetApplicationBaseUrlAsync(branchId) ?? defaultBaseUrl;
            var loginUrl = $"{baseUrl}/Account/Login";
            Func<string?, string?> enc = System.Net.WebUtility.HtmlEncode;
            var htmlBody = $@"
            <h3>Welcome to eClinicPlus+</h3>
            <p>Dear <strong>{enc(name)}</strong>,</p>
            <p>Your account has been created. Here are your login details:</p>
            <table style='border-collapse:collapse;'>
                <tr><td style='padding:4px 12px;font-weight:bold;'>User ID</td><td style='padding:4px 12px;'>{enc(email)}</td></tr>
                <tr><td style='padding:4px 12px;font-weight:bold;'>Email</td><td style='padding:4px 12px;'>{enc(email)}</td></tr>
                <tr><td style='padding:4px 12px;font-weight:bold;'>Password</td><td style='padding:4px 12px;'>{enc(password)}</td></tr>
            </table>
            <p>Please change your password after your first login.</p>
            <p><a href='{loginUrl}'>Click here to login</a></p>
            <br/><p>Regards,<br/>eClinicPlus+ Team</p>";

            const string subject = "eClinicPlus+ — Your Login Credentials";
            var result = await emailService.SendEmailAsync(branchId, email, subject, htmlBody);
            if (!result.Success && fallbackBranchId is int fallback && fallback != branchId)
                result = await emailService.SendEmailAsync(fallback, email, subject, htmlBody);
            if (!result.Success) logger.LogWarning("Login email to {Email} not sent: {Reason}", email, result.Message);
            return (result.Success, result.Message);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Login email to {Email} not sent", email);
            return (false, "the mail server could not be reached");
        }
    }
}
