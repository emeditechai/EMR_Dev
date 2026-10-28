using System.Security.Cryptography;
using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Patient Portal login. The portal user id is the Patient ID (PatientCode); the password is random and must be changed
/// at the first sign-in (SQLScripts/2326).
///   * When Hospital Settings "Required Patient Portal" is Yes for the branch (script 2219), an OPD registration / booking
///     and a B2C LAB booking give a patient without a login one, once, when the patient has a mobile number or an e-mail;
///     the credentials are e-mailed / WhatsApp'd in the background, never blocking the registration or the bill.
///   * Staff create or reset a login from Master > Patient Master (OPDController.PortalLogin), which delivers it with
///     <see cref="SendCredentialsAsync"/>.
/// </summary>
public interface IPatientPortalLoginService
{
    Task TryGenerateAsync(int patientId, string patientCode, string phone, string email, string name, int branchId);

    /// <summary>E-mails the Patient ID and password, and sends them on WhatsApp when the branch has it set up.</summary>
    Task<PortalCredentialDelivery> SendCredentialsAsync(int branchId, string patientCode, string? name, string? email, string? phone,
        string password, bool isReset);
}

public sealed record PortalCredentialDelivery(bool Emailed, bool WhatsApped);

public sealed class PatientPortalLoginService(
    ApplicationDbContext dbContext,
    IServiceScopeFactory scopeFactory,
    IEmailService emailService,
    IWhatsAppService whatsAppService,
    ILogger<PatientPortalLoginService> logger) : IPatientPortalLoginService
{
    // no look-alike characters (0/O, 1/l/I), so a password read out or copied from WhatsApp is typed right
    private const string Upper = "ABCDEFGHJKLMNPQRSTUVWXYZ", Lower = "abcdefghijkmnpqrstuvwxyz", Digits = "23456789";

    /// <summary>A random 8-character portal password with upper-case, lower-case letters and digits.</summary>
    public static string NewPassword()
    {
        const string all = Upper + Lower + Digits;
        var chars = new char[8];
        chars[0] = Upper[RandomNumberGenerator.GetInt32(Upper.Length)];
        chars[1] = Lower[RandomNumberGenerator.GetInt32(Lower.Length)];
        chars[2] = Digits[RandomNumberGenerator.GetInt32(Digits.Length)];
        for (var i = 3; i < chars.Length; i++) chars[i] = all[RandomNumberGenerator.GetInt32(all.Length)];
        RandomNumberGenerator.Shuffle(chars.AsSpan());
        return new string(chars);
    }

    public async Task TryGenerateAsync(int patientId, string patientCode, string phone, string email, string name, int branchId)
    {
        // a mobile number (WhatsApp) or an e-mail is enough to deliver the credentials
        if (string.IsNullOrWhiteSpace(phone) && string.IsNullOrWhiteSpace(email))
            return;

        // Hospital Settings "Required Patient Portal" of the branch (OPD and B2C LAB alike): No = no automatic login
        var required = await dbContext.HospitalSettings
            .Where(s => s.BranchId == branchId && s.IsActive)
            .Select(s => s.LabPatientPortalRequired)
            .FirstOrDefaultAsync();
        if (!required)
            return;

        var isAlreadyGenerated = await dbContext.PatientMasters
            .Where(p => p.PatientId == patientId)
            .Select(p => p.IsLoginGenerated)
            .FirstOrDefaultAsync();

        if (isAlreadyGenerated)
            return;

        TriggerPatientLogin(branchId, patientId, patientCode, name, email, phone);
    }

    // ─── Patient Login Credential (registration): e-mail and WhatsApp ────────────────
    private void TriggerPatientLogin(int activeBranchId, int patientId, string patientCode, string patientName, string? patientEmail, string? patientPhone)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                var passwordHasher = scope.ServiceProvider.GetRequiredService<IPasswordHasherService>();
                var self = scope.ServiceProvider.GetRequiredService<IPatientPortalLoginService>();

                var password = NewPassword();
                var (Hash, Salt) = passwordHasher.HashPassword(password);

                var rowsAffected = await db.Database.GetDbConnection().ExecuteAsync(
                    @"UPDATE PatientMaster
                      SET IsLoginGenerated = 1, PasswordHash = @Hash, Salt = @Salt, IsPasswordchanged = 0
                      WHERE PatientId = @Id AND IsLoginGenerated = 0",
                    new { Hash, Salt, Id = patientId }
                );

                if (rowsAffected == 0) return;

                var sent = await self.SendCredentialsAsync(activeBranchId, patientCode, patientName, patientEmail, patientPhone, password, isReset: false);
                if (!sent.Emailed && !sent.WhatsApped)
                {
                    // nobody received the password: no login, so the portal tells the patient to ask the reception
                    await db.Database.GetDbConnection().ExecuteAsync(
                        @"UPDATE PatientMaster SET IsLoginGenerated = 0, PasswordHash = NULL, Salt = NULL
                          WHERE PatientId = @Id AND PasswordHash = @Hash",
                        new { Id = patientId, Hash });
                    logger.LogWarning("[PORTAL-LOGIN] Credentials for {PatientCode} could not be sent (e-mail / WhatsApp); login not created", patientCode);
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[PORTAL-LOGIN] Generating the portal login of patient {PatientId} failed", patientId);
            }
        });
    }

    public async Task<PortalCredentialDelivery> SendCredentialsAsync(int branchId, string patientCode, string? name, string? email, string? phone,
        string password, bool isReset)
    {
        var hospital = await dbContext.HospitalSettings.Where(h => h.BranchId == branchId).Select(h => h.HospitalName).FirstOrDefaultAsync();
        var hospitalName = string.IsNullOrWhiteSpace(hospital) ? "Our Hospital" : hospital;
        var baseUrl = await emailService.GetApplicationBaseUrlAsync(branchId);
        var portalUrl = string.IsNullOrWhiteSpace(baseUrl) ? null : $"{baseUrl}/PatientPortal/Login";

        var emailed = false;
        if (!string.IsNullOrWhiteSpace(email))
        {
            try
            {
                static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
                var intro = isReset
                    ? "Your patient portal password has been reset. Use the details below to sign in."
                    : "Thank you for registering with us! We have created a secure patient portal account for you. You can use it to view your health records and stay connected with our care team.";
                var rows = new List<(string, string)> { ("Patient ID", H(patientCode)), ("Password", H(password)) };
                if (portalUrl is not null) rows.Add(("Sign in at", $"<a href=\"{H(portalUrl)}\">{H(portalUrl)}</a>"));
                var htmlBody = EmailLayout.Wrap(
                    EmailLayout.Greeting(string.IsNullOrWhiteSpace(name) ? "Patient" : name)
                    + EmailLayout.P(intro)
                    + EmailLayout.Details(rows.ToArray())
                    + EmailLayout.Callout("Sign in with your Patient ID. You will be asked to choose your own password at the first sign-in.", "warn")
                    + EmailLayout.SignOff(hospitalName),
                    heading: isReset ? "Your patient portal password" : $"Welcome to {hospitalName}",
                    organisation: hospitalName);
                var subject = isReset ? $"{hospitalName} - Patient portal password reset" : $"Welcome to {hospitalName} - Your Login Credentials";
                emailed = (await emailService.SendEmailAsync(branchId, email.Trim(), subject, htmlBody)).Success;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "[PORTAL-LOGIN] Credentials e-mail for {PatientCode} failed", patientCode);
            }
        }

        var whatsApped = false;
        if (!string.IsNullOrWhiteSpace(phone))
        {
            try
            {
                var text = $"{hospitalName} - Patient portal\nPatient ID: {patientCode}\nPassword: {password}"
                           + (portalUrl is null ? "" : $"\nSign in: {portalUrl}")
                           + "\nYou will be asked to choose your own password at the first sign-in.";
                whatsApped = (await whatsAppService.SendTextMessageAsync(phone.Trim(), text, branchId, "PORTAL_LOGIN")).Success;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "[PORTAL-LOGIN] Credentials WhatsApp for {PatientCode} failed", patientCode);
            }
        }

        return new PortalCredentialDelivery(emailed, whatsApped);
    }
}
