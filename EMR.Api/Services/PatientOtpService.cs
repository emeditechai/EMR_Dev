using System.Data;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services;

public interface IPatientOtpService
{
    /// <summary>Sends the code when the account can receive one. The caller never learns which e-mails / mobiles can.</summary>
    Task RequestAsync(string login, string? ip);
    /// <summary>The reset token for a right code, else null.</summary>
    Task<string?> VerifyAsync(string login, string code);
    /// <summary>The patient's id when the token was good and the password is set, else null.</summary>
    Task<int?> ResetAsync(string resetToken, string newPassword);
}

/// <summary>
/// First sign-in and forgot password in the patient app (SQLScripts/2486), as the marketing executive app does it
/// (PasswordOtpService, 2384 / 2457): a 6-digit code on WhatsApp to the mobile number of the patient record whose
/// account the e-mail or mobile opens (PatientAccount: the head of family when several patients share it). The
/// limits live in the usp_PatientApp_Otp_* procedures.
/// </summary>
public sealed class PatientOtpService(
    IDbConnectionFactory db,
    IWhatsAppTextSender whatsApp,
    ILogger<PatientOtpService> logger) : IPatientOtpService
{
    private const int CodeMinutes = 10;
    private const int ResetMinutes = 10;

    private sealed record PatientRow(int PatientId, string? FullName, string? Mobile, int? BranchId, bool IsVerified);

    public async Task RequestAsync(string login, string? ip)
    {
        using var con = db.CreateConnection();
        var patient = await FindAsync(con, login);
        if (patient is null || string.IsNullOrWhiteSpace(patient.Mobile) || patient.BranchId is null)
        {
            logger.LogInformation("[PATIENT-OTP] No code sent: no active patient with a mobile number and a branch for this e-mail / mobile");
            return;
        }

        var code = RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
        var otpId = await con.QueryFirstOrDefaultAsync<int?>("dbo.usp_PatientApp_Otp_Create",
            new { patient.PatientId, OtpHash = Sha256($"{patient.PatientId}:{code}"), Minutes = CodeMinutes, Ip = ip },
            commandType: CommandType.StoredProcedure);
        if (otpId is null)
        {
            logger.LogInformation("[PATIENT-OTP] No code sent to patient {PatientId}: limit reached", patient.PatientId);
            return;
        }

        // a patient not verified yet (first sign-in) gets the same code as a verification code
        var text = patient.IsVerified
            ? $"Dear {patient.FullName}, your eCare360Plus patient app password reset code is {code}. It is valid for {CodeMinutes} minutes. Do not share it with anyone."
            : $"Dear {patient.FullName}, your eCare360Plus patient app verification code is {code}. Enter it in the app to set your password. It is valid for {CodeMinutes} minutes. Do not share it with anyone.";
        var result = await whatsApp.SendAsync(patient.BranchId.Value, patient.Mobile, text, "PATIENT_OTP", patient.PatientId,
            logText: text.Replace(code, "******"));
        if (result != WhatsAppSendResult.Sent) logger.LogWarning("[PATIENT-OTP] Code not sent to patient {PatientId}: {Result}", patient.PatientId, result);
    }

    public async Task<string?> VerifyAsync(string login, string code)
    {
        using var con = db.CreateConnection();
        var patient = await FindAsync(con, login);
        if (patient is null) return null;

        var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var verified = await con.QuerySingleAsync<bool>("dbo.usp_PatientApp_Otp_Verify",
            new { patient.PatientId, OtpHash = Sha256($"{patient.PatientId}:{code.Trim()}"), ResetTokenHash = Sha256(token), Minutes = ResetMinutes },
            commandType: CommandType.StoredProcedure);
        return verified ? token : null;
    }

    public async Task<int?> ResetAsync(string resetToken, string newPassword)
    {
        using var con = db.CreateConnection();
        var salt = BCrypt.Net.BCrypt.GenerateSalt(12);
        return await con.QueryFirstOrDefaultAsync<int?>("dbo.usp_PatientApp_Otp_Reset",
            new { ResetTokenHash = Sha256(resetToken), PasswordHash = BCrypt.Net.BCrypt.HashPassword(newPassword, salt), Salt = salt },
            commandType: CommandType.StoredProcedure);
    }

    private static async Task<PatientRow?> FindAsync(IDbConnection con, string login) =>
        await PatientAccount.FindAsync(con, login) is { } id ? await con.QueryFirstOrDefaultAsync<PatientRow>(
        @"SELECT PatientId, LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))) AS FullName,
                 NULLIF(LTRIM(RTRIM(PhoneNumber)), N'') AS Mobile, BranchId,
                 CAST(CASE WHEN Is_App_Verified = 1 AND ISNULL(IsLoginGenerated, 0) = 1 THEN 1 ELSE 0 END AS BIT) AS IsVerified
            FROM dbo.PatientMaster
           WHERE PatientId = @id", new { id }) : null;

    private static string Sha256(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}
