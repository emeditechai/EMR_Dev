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
                        var htmlBody = $@"
                        <div style='font-family: ""Helvetica Neue"", Helvetica, Arial, sans-serif; max-width: 600px; margin: 40px auto; background-color: #ffffff; border: 1px solid #e0e0e0; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 10px rgba(0,0,0,0.05);'>
                            
                            <!-- Header -->
                            <div style='background-color: #0056b3; padding: 30px; text-align: center;'>
                                <h1 style='color: #ffffff; margin: 0; font-size: 24px; font-weight: 600; letter-spacing: 0.5px;'>Welcome to {hospitalName}</h1>
                            </div>
                            
                            <!-- Body -->
                            <div style='padding: 40px 30px;'>
                                <h2 style='color: #333333; font-size: 20px; margin-top: 0;'>Dear {patientName},</h2>
                                <p style='color: #555555; font-size: 16px; line-height: 1.6; margin-bottom: 25px;'>
                                    Thank you for registering with us! We have successfully created a secure patient portal account for you. You can use this account to book appointments, view your health records, and stay connected with our care team.
                                </p>
                                
                                <div style='background-color: #f4f7f6; border-left: 4px solid #0056b3; padding: 20px; border-radius: 4px; margin: 30px 0;'>
                                    <h3 style='color: #333333; margin-top: 0; margin-bottom: 15px; font-size: 16px; text-transform: uppercase; letter-spacing: 1px;'>Your Login Credentials</h3>
                                    <table style='width: 100%; border-collapse: collapse;'>
                                        <tr>
                                            <td style='padding: 8px 0; color: #555555; width: 100px;'><strong>Username:</strong></td>
                                            <td style='padding: 8px 0; color: #333333; font-size: 16px; font-weight: 600;'>{patientEmail}</td>
                                        </tr>
                                        <tr>
                                            <td style='padding: 8px 0; color: #555555;'><strong>Password:</strong></td>
                                            <td style='padding: 8px 0; color: #333333; font-size: 16px; font-weight: 600;'>{password}</td>
                                        </tr>
                                    </table>
                                </div>
                                
                                <p style='color: #555555; font-size: 15px; line-height: 1.5; margin-bottom: 0;'>
                                    <em>For security purposes, we strongly recommend changing your password immediately after your first login.</em>
                                </p>
                            </div>
                            
                            <!-- Footer -->
                            <div style='background-color: #f9f9f9; padding: 20px 30px; text-align: center; border-top: 1px solid #eeeeee;'>
                                <p style='color: #999999; font-size: 12px; margin: 0; line-height: 1.5;'>
                                    This is an automated message generated by {hospitalName}.<br>
                                    Please do not reply directly to this email.
                                </p>
                            </div>
                        </div>";

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
