using System.Security.Cryptography;
using System.Text;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Login > "Forgot password?" (SQLScripts/2293). A reset link is mailed with the mail settings of the Head Office branch
/// (Branchmaster.IsHOBranch = 1) of the user's company. Links are single-use, expire after <see cref="LinkMinutes"/>
/// minutes and only a SHA-256 hash of the token is stored. Callers never learn whether an account exists.
/// </summary>
public interface IPasswordResetService
{
    /// <summary>Sends a reset link to the account matching the user name or email, when there is one that may reset.</summary>
    Task RequestAsync(string userNameOrEmail, string? ip, string fallbackBaseUrl);

    /// <summary>The user name of the account the link belongs to, when the link is still valid.</summary>
    Task<string?> ValidateAsync(string? token);

    /// <summary>Sets the new password; false when the link is invalid, expired or already used.</summary>
    Task<bool> ResetAsync(string token, string newPassword, string? ip);
}

public sealed class PasswordResetService(
    ApplicationDbContext dbContext,
    IDbConnectionFactory db,
    IPasswordHasherService passwordHasher,
    IEmailService emailService,
    ILoginSecurity loginSecurity,
    IAuditLogService auditLog,
    ILogger<PasswordResetService> logger) : IPasswordResetService
{
    public const int LinkMinutes = 30;
    /// <summary>Links a single account may be sent in <see cref="ThrottleMinutes"/> minutes.</summary>
    private const int MaxLinksPerWindow = 3;
    private const int ThrottleMinutes = 15;

    public async Task RequestAsync(string userNameOrEmail, string? ip, string fallbackBaseUrl)
    {
        var key = (userNameOrEmail ?? "").Trim();
        if (key.Length == 0) return;

        // the user name first; else the email address, when exactly one account uses it
        var user = await dbContext.Users.AsNoTracking().FirstOrDefaultAsync(x => x.Username == key);
        if (user is null && key.Contains('@'))
        {
            var byEmail = await dbContext.Users.AsNoTracking().Where(x => x.Email == key).Take(2).ToListAsync();
            if (byEmail.Count == 1) user = byEmail[0];
            else if (byEmail.Count > 1)
            {
                await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link not sent: {byEmail.Count}+ accounts share the email {key}; the user must give the user name.");
                return;
            }
        }

        if (user is null)
        {
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link asked for an unknown user name / email: {key}");
            return;
        }
        if (!user.IsActive || user.IsLockedOut)
        {
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link not sent: account {user.Username} is inactive or locked by the administrator.", user.Id);
            return;
        }
        if (string.IsNullOrWhiteSpace(user.Email) || !user.Email.Contains('@'))
        {
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link not sent: account {user.Username} has no email address.", user.Id);
            return;
        }

        using var con = db.CreateConnection();
        var recent = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM dbo.UserPasswordResetToken WHERE UserId = @userId AND CreatedDate > DATEADD(MINUTE, -@m, GETDATE())",
            new { userId = user.Id, m = ThrottleMinutes });
        if (recent >= MaxLinksPerWindow)
        {
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link not sent: {recent} links already sent to {user.Username} in the last {ThrottleMinutes} minutes.", user.Id);
            return;
        }

        var hoBranchId = await con.ExecuteScalarAsync<int?>(
            @"SELECT TOP 1 BranchID FROM dbo.Branchmaster
               WHERE IsHOBranch = 1 AND IsActive = 1 AND CompanyId = @companyId
               ORDER BY BranchID", new { companyId = user.CompanyId ?? 1 });
        if (hoBranchId is null)
        {
            logger.LogWarning("Password reset for {User}: no active Head Office branch for company {Company}", user.Username, user.CompanyId);
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link not sent to {user.Username}: no active Head Office branch to send mail from.", user.Id);
            return;
        }

        var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var tokenId = await con.ExecuteScalarAsync<int>(@"
            UPDATE dbo.UserPasswordResetToken SET CancelledAt = GETDATE()
             WHERE UserId = @userId AND UsedAt IS NULL AND CancelledAt IS NULL;
            INSERT dbo.UserPasswordResetToken (UserId, TokenHash, ExpiresAt, RequestIp)
            VALUES (@userId, @hash, DATEADD(MINUTE, @mins, GETDATE()), @ip);
            SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new { userId = user.Id, hash = Hash(token), mins = LinkMinutes, ip = Trim(ip) });

        var baseUrl = await emailService.GetApplicationBaseUrlAsync(hoBranchId.Value) ?? fallbackBaseUrl.TrimEnd('/');
        var link = $"{baseUrl}/Account/ResetPassword?token={Uri.EscapeDataString(token)}";
        var name = DisplayName(user);

        (bool Success, string Message) sent;
        try
        {
            sent = await emailService.SendEmailAsync(hoBranchId.Value, user.Email!, "eCare360Plus+ - Reset your password",
                ResetMail(name, user.Username, link));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Password reset mail to {User} not sent", user.Username);
            sent = (false, "the mail server could not be reached");
        }

        if (sent.Success)
        {
            await con.ExecuteAsync("UPDATE dbo.UserPasswordResetToken SET MailSent = 1 WHERE ResetTokenId = @tokenId", new { tokenId });
            await auditLog.LogAsync("Auth", "ForgotPassword", $"Password reset link mailed to {Mask(user.Email!)} for {user.Username}.", user.Id, hoBranchId);
        }
        else
        {
            logger.LogWarning("Password reset mail to {User} not sent: {Reason}", user.Username, sent.Message);
            await auditLog.LogAsync("AuthFailure", "ForgotPassword", $"Reset link for {user.Username} could not be mailed: {sent.Message}", user.Id, hoBranchId);
        }
    }

    public async Task<string?> ValidateAsync(string? token)
    {
        if (!LooksLikeToken(token)) return null;
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<string?>(@"
            SELECT u.Username FROM dbo.UserPasswordResetToken t JOIN dbo.Users u ON u.Id = t.UserId
             WHERE t.TokenHash = @hash AND t.UsedAt IS NULL AND t.CancelledAt IS NULL AND t.ExpiresAt > GETDATE()
               AND u.IsActive = 1 AND ISNULL(u.IsLockedOut, 0) = 0", new { hash = Hash(token!) });
    }

    public async Task<bool> ResetAsync(string token, string newPassword, string? ip)
    {
        if (!LooksLikeToken(token)) return false;

        // claim the link first, so it works once even with two submits at the same time
        using var con = db.CreateConnection();
        var userId = await con.ExecuteScalarAsync<int?>(@"
            UPDATE dbo.UserPasswordResetToken SET UsedAt = GETDATE(), UsedIp = @ip
            OUTPUT inserted.UserId
             WHERE TokenHash = @hash AND UsedAt IS NULL AND CancelledAt IS NULL AND ExpiresAt > GETDATE()",
            new { hash = Hash(token), ip = Trim(ip) });
        if (userId is null) return false;

        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == userId.Value);
        if (user is null || !user.IsActive || user.IsLockedOut) return false;

        var (hash, salt) = passwordHasher.HashPassword(newPassword);
        user.PasswordHash = hash;
        user.Salt = salt;
        user.PasswordLastChanged = DateTime.Now;
        user.MustChangePassword = false;
        user.LastModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();

        // the temporary wrong-password lock ends with the new password; the administrator's lock is untouched
        await loginSecurity.RecordSuccessAsync(user.Id);
        await con.ExecuteAsync(@"UPDATE dbo.UserPasswordResetToken SET CancelledAt = GETDATE()
                                  WHERE UserId = @userId AND UsedAt IS NULL AND CancelledAt IS NULL", new { userId = user.Id });
        await auditLog.LogAsync("Auth", "ResetPassword", $"Password reset with an emailed link by {user.Username}.", user.Id);

        await SendChangedNoticeAsync(con, user, ip);
        return true;
    }

    /// <summary>"Your password was changed" - so the owner notices a reset they did not ask for. Never fails the reset.</summary>
    private async Task SendChangedNoticeAsync(System.Data.IDbConnection con, User user, string? ip)
    {
        if (string.IsNullOrWhiteSpace(user.Email)) return;
        try
        {
            var hoBranchId = await con.ExecuteScalarAsync<int?>(
                "SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE IsHOBranch = 1 AND IsActive = 1 AND CompanyId = @companyId ORDER BY BranchID",
                new { companyId = user.CompanyId ?? 1 });
            if (hoBranchId is null) return;
            await emailService.SendEmailAsync(hoBranchId.Value, user.Email, "eCare360Plus+ - Your password was changed",
                ChangedMail(DisplayName(user), user.Username, ip));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Password changed notice to {User} not sent", user.Username);
        }
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------

    private static string Hash(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    private static bool LooksLikeToken(string? token) =>
        token is { Length: >= 40 and <= 64 } && token.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');

    private static string? Trim(string? ip) => string.IsNullOrEmpty(ip) ? null : ip[..Math.Min(45, ip.Length)];

    private static string DisplayName(User u) =>
        !string.IsNullOrWhiteSpace(u.FullName) ? u.FullName!
        : $"{u.FirstName} {u.LastName}".Trim() is { Length: > 0 } n ? n : u.Username;

    /// <summary>ab****@mail.com - for the audit trail.</summary>
    private static string Mask(string email)
    {
        var at = email.IndexOf('@');
        return at <= 2 ? "***" + email[Math.Max(0, at)..] : email[..2] + new string('*', Math.Min(6, at - 2)) + email[at..];
    }

    private static string Shell(string heading, string inner) => $@"
<div style=""background:#f4f2f8;padding:24px 12px;font-family:Segoe UI,Arial,sans-serif;"">
  <table role=""presentation"" width=""100%"" style=""max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;border-collapse:collapse;"">
    <tr><td style=""background:linear-gradient(135deg,#4a2d75,#644098 50%,#a8407a);background-color:#644098;padding:20px 28px;"">
      <span style=""display:inline-block;background:#ffffff;border-radius:8px;padding:4px 10px;font-size:20px;font-weight:800;"">
        <span style=""color:#1a6efd;"">eCare360</span><span style=""color:#f59e0b;"">Plus</span><span style=""color:#ec4899;"">+</span>
      </span>
    </td></tr>
    <tr><td style=""padding:28px;color:#1b1530;font-size:14px;line-height:1.6;"">
      <h2 style=""margin:0 0 16px;font-size:20px;color:#1b1530;"">{heading}</h2>
      {inner}
    </td></tr>
    <tr><td style=""padding:14px 28px;background:#faf9fc;color:#8c86a3;font-size:12px;border-top:1px solid #eeebf3;"">
      This is an automated message from eCare360Plus+. Please do not reply to this email.
    </td></tr>
  </table>
</div>";

    private static string ResetMail(string name, string userName, string link)
    {
        Func<string?, string?> enc = System.Net.WebUtility.HtmlEncode;
        return Shell("Reset your password", $@"
      <p style=""margin:0 0 12px;"">Dear {enc(name)},</p>
      <p style=""margin:0 0 12px;"">We received a request to reset the password of your eCare360Plus+ account <strong>{enc(userName)}</strong>.
         Click the button below to choose a new password.</p>
      <p style=""margin:24px 0;text-align:center;"">
        <a href=""{enc(link)}"" style=""display:inline-block;background:#ca2e6d;color:#ffffff;text-decoration:none;font-weight:600;padding:12px 28px;border-radius:8px;"">Reset Password</a>
      </p>
      <p style=""margin:0 0 12px;"">This link can be used once and expires in <strong>{LinkMinutes} minutes</strong>.</p>
      <p style=""margin:0 0 12px;color:#6b6880;font-size:13px;"">If the button does not work, copy this address into your browser:<br/>
         <span style=""word-break:break-all;color:#644098;"">{enc(link)}</span></p>
      <p style=""margin:16px 0 0;color:#6b6880;font-size:13px;"">If you did not ask to reset your password, you can ignore this email - your password stays the same.</p>
      <p style=""margin:20px 0 0;"">Regards,<br/>eCare360Plus+ Team</p>");
    }

    private static string ChangedMail(string name, string userName, string? ip)
    {
        Func<string?, string?> enc = System.Net.WebUtility.HtmlEncode;
        return Shell("Your password was changed", $@"
      <p style=""margin:0 0 12px;"">Dear {enc(name)},</p>
      <p style=""margin:0 0 12px;"">The password of your eCare360Plus+ account <strong>{enc(userName)}</strong> was changed on
         <strong>{DateTime.Now:dd-MMM-yyyy hh:mm tt}</strong> using a password reset link{(string.IsNullOrEmpty(ip) ? "" : $" (from address {enc(ip)})")}.</p>
      <p style=""margin:0 0 12px;"">If you made this change, no action is needed.</p>
      <p style=""margin:0 0 12px;color:#b42318;""><strong>If you did not make this change</strong>, contact your system administrator immediately.</p>
      <p style=""margin:20px 0 0;"">Regards,<br/>eCare360Plus+ Team</p>");
    }
}
