using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Patient Portal login for a registered patient: on the first registration with a phone and an e-mail, a portal
/// password is generated and the credentials are e-mailed (in the background, never blocking the registration).
/// Used by OPD registration (always) and by B2C LAB booking when Hospital Settings > LAB "Required Patient Portal" is
/// Yes (script 2219). Moved unchanged from OPDController.
/// </summary>
public interface IPatientPortalLoginService
{
    Task TryGenerateAsync(int patientId, string patientCode, string phone, string email, string name, int branchId);
}

public sealed class PatientPortalLoginService(ApplicationDbContext dbContext, IServiceScopeFactory scopeFactory) : IPatientPortalLoginService
{
    public async Task TryGenerateAsync(int patientId, string patientCode, string phone, string email, string name, int branchId)
    {
        if (string.IsNullOrWhiteSpace(phone) || string.IsNullOrWhiteSpace(email))
            return;

        var isAlreadyGenerated = await dbContext.PatientMasters
            .Where(p => p.PatientId == patientId)
            .Select(p => p.IsLoginGenerated)
            .FirstOrDefaultAsync();

        if (isAlreadyGenerated)
            return;


        TriggerPatientLoginEmail(branchId, patientId, patientCode, name, email);
    }

    // ─── Email: Patient Login Credential ────────────────────────────────────────────
    private void TriggerPatientLoginEmail(int activeBranchId, int patientId, string patientCode, string patientName, string patientEmail)
    {
        try
        {

            _ = Task.Run(async () =>
            {
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                    var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                    var passwordHasher = scope.ServiceProvider.GetRequiredService<IPasswordHasherService>();

                    // Generate Password
                    var password = $"{patientCode}{DateTime.Now.Year}";
                    var (Hash, Salt) = passwordHasher.HashPassword(password);

                    // Update DB directly
                    var rowsAffected = await db.Database.GetDbConnection().ExecuteAsync(
                        @"UPDATE PatientMaster 
                          SET IsLoginGenerated = 1, PasswordHash = @Hash, Salt = @Salt, IsPasswordchanged = 0 
                          WHERE PatientId = @Id AND IsLoginGenerated = 0",
                        new { Hash, Salt, Id = patientId }
                    );

                    if (rowsAffected > 0)
                    {
                        var hospital = await db.HospitalSettings.FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                        var hospitalName = hospital?.HospitalName ?? "Our Hospital";

                        var subject = $"Welcome to {hospitalName} - Your Login Credentials";
                        static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
                        var htmlBody = EmailLayout.Wrap(
                            EmailLayout.Greeting(patientName ?? "Patient")
                            + EmailLayout.P("Thank you for registering with us! We have created a secure patient portal account for you. You can use it to book appointments, view your health records and stay connected with our care team.")
                            + EmailLayout.Details(("Username", H(patientEmail)), ("Password", H(password)))
                            + EmailLayout.Callout("For your security, please change your password after your first login.", "warn")
                            + EmailLayout.SignOff(hospitalName),
                            heading: $"Welcome to {hospitalName}",
                            organisation: hospitalName);

                        await emailSvc.SendEmailAsync(activeBranchId, patientEmail, subject, htmlBody);
                        Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Sent login credentials to PatientId: {patientId}, Email: {patientEmail}");
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Error generating/sending login credentials: {ex}");
                }
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Error in TriggerPatientLoginEmail setup: {ex}");
        }
    }
}
