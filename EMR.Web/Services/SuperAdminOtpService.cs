using System.Security.Cryptography;
using System.Text;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

/// <summary>
/// Super Admin sign-in second step (SQLScripts/2579). After the password is accepted, a 6-digit code is sent on WhatsApp
/// (Users.PhoneNumber / Phone) and by e-mail (Users.Email); the session starts only when the code is typed.
/// A code works once, expires after <see cref="CodeMinutes"/> minutes and is cancelled after <see cref="MaxWrongTries"/>
/// wrong tries. Only a SHA-256 hash of the code is stored.
/// </summary>
public interface ISuperAdminOtpService
{
    /// <summary>Sends a new code (the earlier ones stop working). Null Error = sent on at least one channel.</summary>
    Task<OtpSendResult> SendAsync(User user, string? ip);

    /// <summary>Checks the code typed for the challenge.</summary>
    Task<OtpCheck> VerifyAsync(int otpId, int userId, string code);
}

public sealed record OtpSendResult(int OtpId, string? Error, string? SentTo);

public enum OtpCheck { Ok, Wrong, Expired, TooManyTries }

public sealed class SuperAdminOtpService(
    IDbConnectionFactory db,
    IWhatsAppService whatsApp,
    IEmailService email,
    IAuditLogService audit,
    IConfiguration config,
    ILogger<SuperAdminOtpService> logger) : ISuperAdminOtpService
{
    public const int CodeMinutes = 5;
    public const int MaxWrongTries = 5;
    /// <summary>Codes a single account may be sent in <see cref="ThrottleMinutes"/> minutes.</summary>
    public const int MaxCodesPerWindow = 5;
    public const int ThrottleMinutes = 15;

    public async Task<OtpSendResult> SendAsync(User user, string? ip)
    {
        using var con = db.CreateConnection();
        var recent = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM dbo.UserLoginOtp WHERE UserId = @userId AND CreatedDate > DATEADD(MINUTE, -@m, GETDATE())",
            new { userId = user.Id, m = ThrottleMinutes });
        if (recent >= MaxCodesPerWindow)
        {
            await audit.LogAsync("AuthFailure", "LoginOtp", $"Sign-in code not sent: {recent} codes already sent to {user.Username} in the last {ThrottleMinutes} minutes.", user.Id);
            return new(0, $"Too many codes were sent in the last {ThrottleMinutes} minutes. Try again later.", null);
        }

        // appsettings SuperAdminOtp:WhatsAppNumbers / SuperAdminOtp:Emails when set (the same recipients for every Super Admin);
        // otherwise the Super Admin's own mobile / e-mail from User Master
        var mobiles = List("SuperAdminOtp:WhatsAppNumbers");
        if (mobiles.Count == 0 && new[] { user.PhoneNumber, user.Phone }.Select(x => x?.Trim()).FirstOrDefault(x => !string.IsNullOrEmpty(x)) is { } own)
            mobiles.Add(own);
        var mails = List("SuperAdminOtp:Emails").Where(ValidMail).ToList();
        if (mails.Count == 0 && user.Email?.Trim() is { } ownMail && ValidMail(ownMail))
            mails.Add(ownMail);

        // the user's first active branch sends the WhatsApp / mail (Head Office when the user has none)
        var branchId = await con.ExecuteScalarAsync<int?>(@"
            SELECT COALESCE(
                (SELECT TOP 1 ub.BranchID FROM dbo.UserBranches ub JOIN dbo.Branchmaster b ON b.BranchID = ub.BranchID
                  WHERE ub.UserId = @userId AND ub.IsActive = 1 AND b.IsActive = 1 ORDER BY b.IsHOBranch DESC, ub.BranchID),
                (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE IsHOBranch = 1 AND IsActive = 1 ORDER BY BranchID))",
            new { userId = user.Id });

        var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
        var otpId = await con.ExecuteScalarAsync<int>(@"
            UPDATE dbo.UserLoginOtp SET CancelledAt = GETDATE() WHERE UserId = @userId AND UsedAt IS NULL AND CancelledAt IS NULL;
            INSERT dbo.UserLoginOtp (UserId, CodeHash, ExpiresAt, RequestIp) VALUES (@userId, '', DATEADD(MINUTE, @mins, GETDATE()), @ip);
            SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new { userId = user.Id, mins = CodeMinutes, ip = string.IsNullOrEmpty(ip) ? null : ip[..Math.Min(45, ip.Length)] });
        await con.ExecuteAsync("UPDATE dbo.UserLoginOtp SET CodeHash = @h WHERE LoginOtpId = @otpId", new { h = Hash(otpId, code), otpId });

        bool waSent = false, mailSent = false;
        var waTo = new List<string>();
        var mailTo = new List<string>();
        var problems = new List<string>();
        if (branchId is null) problems.Add("no active branch to send from");
        else
        {
            if (mobiles.Count == 0) problems.Add("no mobile number in User Master");
            var text = $"🔐 *eCare360Plus+ sign-in code*\n\nSuper Admin sign-in code for {user.Username} is *{code}*.\n" +
                       $"It expires in {CodeMinutes} minutes and works once.\n\n" +
                       "Do not share it with anyone. If no one is signing in now, change the password at once.";
            foreach (var mobile in mobiles)
            {
                try
                {
                    var r = await whatsApp.SendTextMessageAsync(mobile, text, branchId.Value, "LOGIN_OTP", user.Id);
                    if (r.Success) { waSent = true; waTo.Add(MaskMobile(mobile)); }
                    else problems.Add($"WhatsApp {MaskMobile(mobile)}: " + (r.ErrorMessage ?? "not sent"));
                }
                catch (Exception ex) { logger.LogWarning(ex, "Sign-in code WhatsApp for {User} failed", user.Username); problems.Add($"WhatsApp {MaskMobile(mobile)} could not be reached"); }
            }

            if (mails.Count == 0) problems.Add("no e-mail address");
            var body = Mail(user, code, ip);
            foreach (var mail in mails)
            {
                try
                {
                    var r = await email.SendEmailAsync(branchId.Value, mail, "eCare360Plus+ - Your sign-in code", body);
                    if (r.Success) { mailSent = true; mailTo.Add(MaskEmail(mail)); }
                    else problems.Add($"e-mail {MaskEmail(mail)}: " + r.Message);
                }
                catch (Exception ex) { logger.LogWarning(ex, "Sign-in code mail for {User} failed", user.Username); problems.Add($"e-mail {MaskEmail(mail)}: the mail server could not be reached"); }
            }
        }

        await con.ExecuteAsync("UPDATE dbo.UserLoginOtp SET SentWhatsApp = @waSent, SentEmail = @mailSent WHERE LoginOtpId = @otpId",
            new { waSent, mailSent, otpId });

        if (!waSent && !mailSent)
        {
            await con.ExecuteAsync("UPDATE dbo.UserLoginOtp SET CancelledAt = GETDATE() WHERE LoginOtpId = @otpId", new { otpId });
            await audit.LogAsync("AuthFailure", "LoginOtp", $"Super Admin sign-in code for {user.Username} could not be sent: {string.Join("; ", problems)}.", user.Id, branchId);
            return new(0, "The sign-in code could not be sent on WhatsApp or by e-mail. Contact your system administrator.", null);
        }

        var to = string.Join(" and ", new[] { waSent ? "WhatsApp " + string.Join(", ", waTo) : null, mailSent ? "e-mail " + string.Join(", ", mailTo) : null }.Where(x => x != null));
        await audit.LogAsync("Auth", "LoginOtp", $"Super Admin sign-in code sent to {user.Username} on {to}" +
            (problems.Count > 0 ? $" (not sent: {string.Join("; ", problems)})" : "") + ".", user.Id, branchId);
        return new(otpId, null, to);
    }

    public async Task<OtpCheck> VerifyAsync(int otpId, int userId, string code)
    {
        code = new string((code ?? "").Where(char.IsAsciiDigit).ToArray());
        using var con = db.CreateConnection();
        // claim the code in one statement, so it works once even with two submits at the same time
        var used = await con.ExecuteScalarAsync<int?>(@"
            UPDATE dbo.UserLoginOtp SET UsedAt = GETDATE()
            OUTPUT inserted.LoginOtpId
             WHERE LoginOtpId = @otpId AND UserId = @userId AND CodeHash = @h
               AND UsedAt IS NULL AND CancelledAt IS NULL AND ExpiresAt > GETDATE() AND WrongAttempts < @max",
            new { otpId, userId, h = code.Length == 6 ? Hash(otpId, code) : "-", max = MaxWrongTries });
        if (used is not null) return OtpCheck.Ok;

        var row = await con.QuerySingleOrDefaultAsync<(int WrongAttempts, bool Open)>(@"
            UPDATE dbo.UserLoginOtp
               SET WrongAttempts = WrongAttempts + 1,
                   CancelledAt = CASE WHEN WrongAttempts + 1 >= @max THEN GETDATE() ELSE CancelledAt END
            OUTPUT inserted.WrongAttempts, CAST(CASE WHEN deleted.ExpiresAt > GETDATE() THEN 1 ELSE 0 END AS BIT)
             WHERE LoginOtpId = @otpId AND UserId = @userId AND UsedAt IS NULL AND CancelledAt IS NULL",
            new { otpId, userId, max = MaxWrongTries });
        if (row == default) return OtpCheck.Expired;              // used, cancelled or unknown
        if (!row.Open) return OtpCheck.Expired;
        return row.WrongAttempts >= MaxWrongTries ? OtpCheck.TooManyTries : OtpCheck.Wrong;
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------

    private List<string> List(string key) =>
        (config.GetSection(key).Get<string[]>() ?? [])
            .Select(x => x?.Trim()).Where(x => !string.IsNullOrEmpty(x)).Select(x => x!)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    private static bool ValidMail(string m) =>
        m.Contains('@') && !m.EndsWith(".invalid", StringComparison.OrdinalIgnoreCase);

    private static string Hash(int otpId, string code) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{otpId}:{code}")));

    public static string MaskMobile(string m)
    {
        var d = new string(m.Where(char.IsAsciiDigit).ToArray());
        return d.Length <= 4 ? "****" : new string('*', d.Length - 4) + d[^4..];
    }

    public static string MaskEmail(string e)
    {
        var at = e.IndexOf('@');
        return at <= 2 ? "***" + e[Math.Max(0, at)..] : e[..2] + new string('*', Math.Min(6, at - 2)) + e[at..];
    }

    private static string Mail(User u, string code, string? ip)
    {
        var name = !string.IsNullOrWhiteSpace(u.FullName) ? u.FullName! : $"{u.FirstName} {u.LastName}".Trim() is { Length: > 0 } n ? n : u.Username;
        return EmailLayout.Wrap(
            EmailLayout.Greeting(name)
            + EmailLayout.P("Use this code to finish signing in to eCare360Plus+ as Super Admin:")
            + $"<p style=\"font-size:28px;font-weight:700;letter-spacing:8px;text-align:center;margin:18px 0;\">{code}</p>"
            + EmailLayout.P($"It expires in <strong>{CodeMinutes} minutes</strong> and works once. Do not share it with anyone.")
            + EmailLayout.Details(("Requested on", DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt")), ("From address", System.Net.WebUtility.HtmlEncode(ip) ?? ""))
            + EmailLayout.Callout("<strong>If you did not try to sign in</strong>, someone knows your password: change it now.", "danger")
            + EmailLayout.SignOff("eCare360Plus+ Team"),
            heading: "Your sign-in code");
    }
}
