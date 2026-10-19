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
            var htmlBody = EmailLayout.Wrap(
                EmailLayout.Greeting(name)
                + EmailLayout.P("Your eCare360Plus+ account has been created. Here are your login details:")
                + EmailLayout.Details(("User ID", enc(email) ?? ""), ("Email", enc(email) ?? ""), ("Password", enc(password) ?? ""))
                + EmailLayout.Callout("For your security, please change this password after your first login.", "warn")
                + EmailLayout.Button("Sign In", loginUrl)
                + EmailLayout.SignOff("eCare360Plus+ Team"),
                heading: "Welcome to eCare360Plus+");

            const string subject = "eCare360Plus+ - Your Login Credentials";
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
