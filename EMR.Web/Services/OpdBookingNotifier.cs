using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// OPD booking confirmation: renders the OPD bill to PDF and sends it by WhatsApp (IWhatsAppService.TriggerOpdBillWhatsAppAsync)
/// and by e-mail ("Booking Confirmation" template), in the background. Used by OPD bookings and by the patient app.
/// </summary>
public interface IOpdBookingNotifier
{
    void Queue(int? branchId, int opdServiceId, string hostUrl);
}

public sealed class OpdBookingNotifier(IServiceScopeFactory scopeFactory) : IOpdBookingNotifier
{
    public void Queue(int? branchId, int opdServiceId, string hostUrl)
    {
        try
        {
            var activeBranchId = branchId ?? 1;

            _ = Task.Run(async () =>
            {
                string? tempPdfPath = null;
                List<System.Net.Mail.Attachment> attachments = new();
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

                    // Fetch booking details (poll if token is not generated yet, up to 5 attempts)
                    PatientOPDService? booking = null;
                    for (int i = 0; i < 5; i++)
                    {
                        booking = await db.PatientOPDServices
                            .AsNoTracking()
                            .FirstOrDefaultAsync(b => b.OPDServiceId == opdServiceId);

                        if (booking != null && !string.IsNullOrEmpty(booking.TokenNo))
                        {
                            Console.WriteLine($"[DEBUG-OPD-NOTIF] Found TokenNo: '{booking.TokenNo}' at attempt {i + 1}");
                            break;
                        }

                        if (booking != null && booking.TotalAmount == 0)
                        {
                            break;
                        }

                        Console.WriteLine($"[DEBUG-OPD-NOTIF] Waiting for TokenNo for OPDServiceId {opdServiceId} (attempt {i + 1})...");
                        await Task.Delay(2500);
                    }

                    if (booking == null)
                    {
                        Console.WriteLine($"[DEBUG-OPD-NOTIF] Booking ID {opdServiceId} not found, skipping notifications.");
                        return;
                    }

                    if (booking.BranchId.HasValue && booking.BranchId.Value > 0)
                    {
                        activeBranchId = booking.BranchId.Value;
                    }

                    // 1. Generate OPD Bill PDF via headless Chrome so both WhatsApp and Email can use it
                    try
                    {
                        var safeBillNo = (booking.OPDBillNo ?? opdServiceId.ToString()).Replace("/", "_").Replace("\\", "_");
                        tempPdfPath = Path.Combine(Path.GetTempPath(), $"OPD_Bill_{safeBillNo}.pdf");
                        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{opdServiceId}-emr"));
                        var billUrl = $"{hostUrl}/OPD/PrintBillAnonymous?id={opdServiceId}&secret={Uri.EscapeDataString(secret)}";

                        Console.WriteLine($"[DEBUG-OPD-NOTIF] Generating PDF for OPD bill. URL: {billUrl}, Output: {tempPdfPath}");

                        var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{tempPdfPath}\" \"{billUrl}\"";
                        using var process = new System.Diagnostics.Process();
                        process.StartInfo.FileName = OperatingSystem.IsWindows() ? "chrome" : "google-chrome";
                        if (OperatingSystem.IsMacOS()) process.StartInfo.FileName = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
                        process.StartInfo.Arguments = chromeArgs;
                        process.StartInfo.UseShellExecute = true;
                        process.Start();
                        await process.WaitForExitAsync();
                    }
                    catch (Exception pdfEx)
                    {
                        Console.WriteLine($"[DEBUG-OPD-NOTIF] Error generating OPD bill PDF: {pdfEx.Message}");
                    }

                    // 2. Trigger WhatsApp notification (attaches generated bill PDF)
                    try
                    {
                        var whatsAppSvc = scope.ServiceProvider.GetRequiredService<IWhatsAppService>();
                        await whatsAppSvc.TriggerOpdBillWhatsAppAsync(activeBranchId, opdServiceId, tempPdfPath, hostUrl);
                    }
                    catch (Exception waEx)
                    {
                        Console.WriteLine($"[DEBUG-WHATSAPP-TRIGGER] Error in TriggerBookingWhatsApp: {waEx.Message}");
                    }

                    // 3. Trigger Email notification (if patient has email and branch setting enabled)
                    var patient = await db.PatientMasters.FirstOrDefaultAsync(p => p.PatientId == booking.PatientId);
                    var patientEmail = patient?.EmailId;

                    if (!string.IsNullOrWhiteSpace(patientEmail))
                    {
                        var settings = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                        if (settings != null && settings.EmailNotificationRequired)
                        {
                            var template = await db.EmailTemplates
                                .FirstOrDefaultAsync(t => t.BranchId == activeBranchId && t.TemplateName == "Booking Confirmation" && t.IsActive);

                            if (template != null)
                            {
                                var doctorName = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<string>(
                                    "SELECT FullName FROM DoctorMaster WHERE DoctorId = @Id", new { Id = booking.ConsultingDoctorId });
                                var hospital = await db.HospitalSettings.FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                                var hospitalName = hospital?.HospitalName ?? "Our Hospital";

                                var slotTimeStr = booking.AppointmentTime.HasValue 
                                    ? DateTime.Today.Add(booking.AppointmentTime.Value).ToString("hh:mm tt") 
                                    : "N/A";

                                // the same fields in the subject and the body (Utility > Email Templates lets either use them)
                                string FillBooking(string text) => text
                                    .Replace("{{PatientName}}", $"{patient?.FirstName} {patient?.LastName}")
                                    .Replace("{{DoctorName}}", doctorName ?? "")
                                    .Replace("{{TokenNo}}", booking.TokenNo ?? "Pending")
                                    .Replace("{{TotalAmount}}", booking.TotalAmount?.ToString("0.00") ?? "0.00")
                                    .Replace("{{VisitDate}}", booking.VisitDate.ToString("dd-MMM-yyyy"))
                                    .Replace("{{SlotTime}}", slotTimeStr)
                                    .Replace("{{HospitalName}}", hospitalName);
                                var subject = FillBooking(template.Subject);
                                var htmlBody = FillBooking(template.HtmlBody);

                                if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                                {
                                    var attachment = new System.Net.Mail.Attachment(tempPdfPath, "application/pdf");
                                    attachments.Add(attachment);
                                }

                                var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                                await emailSvc.SendEmailAsync(activeBranchId, patientEmail, subject, htmlBody, attachments.Any() ? attachments : null);
                                Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Email sent to {patientEmail} successfully.");
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error in TriggerBookingEmail: {ex}");
                }
                finally
                {
                    foreach (var att in attachments)
                    {
                        try { att.Dispose(); } catch { }
                    }

                    if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                    {
                        try { System.IO.File.Delete(tempPdfPath); } catch { }
                    }
                }
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error scheduling booking email: {ex}");
        }
    }
}
