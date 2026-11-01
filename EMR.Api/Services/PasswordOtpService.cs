using System.Data;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using EMR.Api.Data;
using EMR.Shared.Security;

namespace EMR.Api.Services;

public interface IPasswordOtpService
{
    /// <summary>Sends the code when the login can receive one. The caller never learns which logins can.</summary>
    Task RequestAsync(string username, string? ip);
    /// <summary>The reset token for a right code, else null.</summary>
    Task<string?> VerifyAsync(string username, string code);
    /// <summary>The user's id when the token was good and the password is changed, else null.</summary>
    Task<int?> ResetAsync(string resetToken, string newPassword);
}

/// <summary>Forgot password in the phlebotomist app (SQLScripts/2384). The limits live in the usp_Auth_PasswordOtp_* procedures.</summary>
public sealed class PasswordOtpService(
    IDbConnectionFactory db,
    IWhatsAppTextSender whatsApp,
    ILoginSecurity loginSecurity,
    ILogger<PasswordOtpService> logger) : IPasswordOtpService
{
    private const int CodeMinutes = 10;
    private const int ResetMinutes = 10;

    private sealed record UserRow(int Id, string? FullName, string? Mobile, int? BranchId);

    public async Task RequestAsync(string username, string? ip)
    {
        using var con = db.CreateConnection();
        var user = await FindAsync(con, username);
        if (user is null || string.IsNullOrWhiteSpace(user.Mobile) || user.BranchId is null)
        {
            logger.LogInformation("[PASSWORD-OTP] No code sent: no active login with a mobile number and a branch for this username");
            return;
        }

        var code = RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
        var otpId = await con.QueryFirstOrDefaultAsync<int?>("dbo.usp_Auth_PasswordOtp_Create",
            new { UserId = user.Id, OtpHash = Sha256($"{user.Id}:{code}"), Minutes = CodeMinutes, Ip = ip }, commandType: CommandType.StoredProcedure);
        if (otpId is null)
        {
            logger.LogInformation("[PASSWORD-OTP] No code sent to user {UserId}: limit reached", user.Id);
            return;
        }

        var result = await whatsApp.SendAsync(user.BranchId.Value, user.Mobile,
            $"Dear {user.FullName}, your eCare360Plus password reset code is {code}. It is valid for {CodeMinutes} minutes. Do not share it with anyone.");
        if (result != WhatsAppSendResult.Sent) logger.LogWarning("[PASSWORD-OTP] Code not sent to user {UserId}: {Result}", user.Id, result);
    }

    public async Task<string?> VerifyAsync(string username, string code)
    {
        using var con = db.CreateConnection();
        var user = await FindAsync(con, username);
        if (user is null) return null;

        var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var verified = await con.QuerySingleAsync<bool>("dbo.usp_Auth_PasswordOtp_Verify",
            new { UserId = user.Id, OtpHash = Sha256($"{user.Id}:{code.Trim()}"), ResetTokenHash = Sha256(token), Minutes = ResetMinutes },
            commandType: CommandType.StoredProcedure);
        return verified ? token : null;
    }

    public async Task<int?> ResetAsync(string resetToken, string newPassword)
    {
        using var con = db.CreateConnection();
        var userId = await con.QueryFirstOrDefaultAsync<int?>("dbo.usp_Auth_PasswordOtp_Reset",
            new { ResetTokenHash = Sha256(resetToken), PasswordHash = BCrypt.Net.BCrypt.HashPassword(newPassword, 12) },
            commandType: CommandType.StoredProcedure);
        if (userId is null) return null;

        await con.ExecuteAsync("dbo.usp_Auth_RefreshToken_RevokeUser", new { UserId = userId, Reason = "Password reset by WhatsApp code" },
            commandType: CommandType.StoredProcedure);
        await loginSecurity.RecordSuccessAsync(userId.Value);
        return userId;
    }

    private static Task<UserRow?> FindAsync(IDbConnection con, string username) => con.QueryFirstOrDefaultAsync<UserRow>(
        @"SELECT u.Id, COALESCE(u.FullName, u.Username) AS FullName, COALESCE(NULLIF(u.PhoneNumber, N''), NULLIF(u.Phone, N'')) AS Mobile,
                 (SELECT TOP 1 ub.BranchID FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.IsActive = 1 ORDER BY ub.BranchID) AS BranchId
            FROM dbo.Users u
           WHERE u.Username = @username AND u.IsActive = 1 AND ISNULL(u.IsLockedOut, 0) = 0", new { username = username.Trim() });

    private static string Sha256(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}
