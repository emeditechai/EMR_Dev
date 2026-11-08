using EMR.Web.Controllers;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// LAB booking confirmation for a walk-in (B2C) patient, as LAB > B2C Booking sends it: the LAB bill is rendered to
/// PDF and sent by WhatsApp (IWhatsAppService.TriggerLabBillWhatsAppAsync) and, when the branch has LAB e-mail on, by
/// e-mail - in the background, so a slow or failed send never holds up the booking. Used by the patient app.
/// </summary>
public interface ILabBookingNotifier
{
    void Queue(int branchId, int labOrderId, string billNo, string? patientEmail, string patientName, string hostUrl);
}

public sealed class LabBookingNotifier(IServiceScopeFactory scopeFactory, ILogger<LabBookingNotifier> logger) : ILabBookingNotifier
{
    public void Queue(int branchId, int labOrderId, string billNo, string? patientEmail, string patientName, string hostUrl)
    {
        _ = Task.Run(async () =>
        {
            using var scope = scopeFactory.CreateScope();
            string? tempPdfPath = null;
            try
            {
                // 1. the LAB bill as PDF (the anonymous bill print, through headless Chrome), for WhatsApp and e-mail
                try
                {
                    tempPdfPath = Path.Combine(Path.GetTempPath(), $"Lab_Bill_{billNo.Replace("/", "_").Replace("\\", "_")}.pdf");
                    var billUrl = $"{hostUrl}/LabOrderBooking/PrintBillAnonymous?labOrderId={labOrderId}&secret={Uri.EscapeDataString($"lab_print_{labOrderId}")}";
                    using var process = new System.Diagnostics.Process();
                    process.StartInfo.FileName = OperatingSystem.IsWindows() ? "chrome" : "google-chrome";
                    if (OperatingSystem.IsMacOS()) process.StartInfo.FileName = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
                    process.StartInfo.Arguments = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{tempPdfPath}\" \"{billUrl}\"";
                    process.StartInfo.UseShellExecute = true;
                    process.Start();
                    await process.WaitForExitAsync();
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "[LAB-NOTIF] Bill PDF could not be made for LabOrderId {Id}", labOrderId);
                }

                // 2. WhatsApp, with the bill attached
                try
                {
                    await scope.ServiceProvider.GetRequiredService<IWhatsAppService>().TriggerLabBillWhatsAppAsync(branchId, labOrderId, tempPdfPath, hostUrl);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "[WhatsApp] LAB bill notification failed for LabOrderId {Id}", labOrderId);
                }

                // 3. e-mail, when the patient has one and the branch sends LAB e-mails
                if (!string.IsNullOrWhiteSpace(patientEmail))
                {
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                    var hs = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(s => s.BranchId == branchId && s.IsActive);
                    if (hs != null && hs.LabEmailNotificationRequired)
                    {
                        var email = scope.ServiceProvider.GetRequiredService<IEmailService>();
                        var subject = $"Your Lab Order Bill [{billNo}] - {hs.HospitalName}";
                        var body = LabBillEmail.Body(hs.HospitalName, patientName, billNo, hs.Address);
                        if (!string.IsNullOrEmpty(tempPdfPath) && File.Exists(tempPdfPath))
                        {
                            using var attachment = new System.Net.Mail.Attachment(tempPdfPath, "application/pdf");
                            await email.SendEmailAsync(branchId, patientEmail, subject, body, new[] { attachment });
                        }
                        else
                        {
                            await email.SendEmailAsync(branchId, patientEmail, subject, body);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[LAB-NOTIF] Booking notification failed for LabOrderId {Id}", labOrderId);
            }
            finally
            {
                if (!string.IsNullOrEmpty(tempPdfPath) && File.Exists(tempPdfPath))
                {
                    try { File.Delete(tempPdfPath); } catch { }
                }
            }
        });
    }
}
