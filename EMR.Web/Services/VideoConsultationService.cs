using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class VideoConsultationService(
    ApplicationDbContext dbContext,
    IWherebyService wherebyService,
    IEmailService emailService) : IVideoConsultationService
{
    public async Task CreateAndDispatchAsync(
        int opdServiceId, int doctorId, int patientId,
        DateTime appointmentDate, TimeSpan slotStartTime, TimeSpan slotEndTime,
        int graceTimeMinutes, int branchId, string createdBy)
    {
        Console.WriteLine($"[VIDEO] Starting Whereby room creation for OPDServiceId={opdServiceId}, DoctorId={doctorId}, PatientId={patientId}");

        // ── Step 1: Call Whereby API ─────────────────────────────────────────
        var result = await wherebyService.CreateMeetingAsync(
            patientId, appointmentDate, slotStartTime, slotEndTime, graceTimeMinutes);

        var prefix = wherebyService.GenerateMeetingPrefix(patientId, appointmentDate, slotStartTime);

        // ── Step 2: Save consultation record ─────────────────────────────────
        var consultation = new VideoConsultation
        {
            OPDServiceId     = opdServiceId,
            DoctorId         = doctorId,
            PatientId        = patientId,
            RoomNamePrefix   = prefix,
            GraceTimeMinutes = graceTimeMinutes,
            CreatedDate      = DateTime.Now,
            CreatedBy        = createdBy
        };

        if (result == null)
        {
            consultation.Status       = "Failed";
            consultation.WherebyMeetingId = "ERROR";
            consultation.DoctorHostUrl    = string.Empty;
            consultation.PatientRoomUrl   = string.Empty;
            consultation.MeetingStartDate = DateTime.UtcNow;
            consultation.MeetingEndDate   = DateTime.UtcNow;
            consultation.ErrorMessage     = "Whereby API call failed. Check logs.";
            dbContext.VideoConsultations.Add(consultation);
            await dbContext.SaveChangesAsync();
            Console.WriteLine($"[VIDEO] Whereby API failed for OPDServiceId={opdServiceId}. Saved Failed record.");
            return;
        }

        consultation.WherebyMeetingId = result.MeetingId;
        consultation.DoctorHostUrl    = result.HostRoomUrl;
        consultation.PatientRoomUrl   = result.RoomUrl;
        consultation.MeetingStartDate = result.StartDate;
        consultation.MeetingEndDate   = result.EndDate;
        consultation.Status           = "Scheduled";

        dbContext.VideoConsultations.Add(consultation);
        await dbContext.SaveChangesAsync();
        Console.WriteLine($"[VIDEO] Saved VideoConsultation record Id={consultation.ConsultationId}");

        // ── Step 3: Fetch doctor and patient details ──────────────────────────
        var con = dbContext.Database.GetDbConnection();
        var doctorRow = await con.QueryFirstOrDefaultAsync<(string Name, string? Email)>(
            "SELECT FullName AS Name, EmailId AS Email FROM DoctorMaster WHERE DoctorId = @DoctorId",
            new { DoctorId = doctorId });

        var patient = await dbContext.PatientMasters.AsNoTracking()
            .FirstOrDefaultAsync(p => p.PatientId == patientId);

        var patientName  = patient != null ? $"{patient.FirstName} {patient.LastName}".Trim() : "Patient";
        var doctorName   = string.IsNullOrWhiteSpace(doctorRow.Name) ? "Doctor" : doctorRow.Name;
        var patientEmail = patient?.EmailId;
        var doctorEmail  = doctorRow.Email;

        var apptDateStr  = appointmentDate.ToString("dd-MMM-yyyy");
        var slotStartStr = DateTime.Today.Add(slotStartTime).ToString("hh:mm tt");
        var slotEndStr   = DateTime.Today.Add(slotEndTime).ToString("hh:mm tt");

        // ── Step 4: Send Doctor Email ─────────────────────────────────────────
        if (!string.IsNullOrWhiteSpace(doctorEmail))
        {
            try
            {
                var doctorSubject = $"Video Consultation Scheduled — {patientName} on {apptDateStr} at {slotStartStr}";
                var doctorBody = BuildDoctorEmailBody(
                    doctorName, patientName, apptDateStr, slotStartStr, slotEndStr,
                    graceTimeMinutes, result.HostRoomUrl);

                await emailService.SendEmailAsync(branchId, doctorEmail, doctorSubject, doctorBody);
                consultation.DoctorEmailSent = true;
                Console.WriteLine($"[VIDEO] Doctor email sent to {doctorEmail}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[VIDEO] Failed to send doctor email: {ex.Message}");
                consultation.ErrorMessage = (consultation.ErrorMessage ?? "") + $" | DocEmailErr: {ex.Message}";
            }
        }
        else
        {
            Console.WriteLine($"[VIDEO] No email for DoctorId={doctorId}, skipping doctor email.");
        }

        // ── Step 5: Send Patient Email ────────────────────────────────────────
        if (!string.IsNullOrWhiteSpace(patientEmail))
        {
            try
            {
                var patientSubject = $"Your Video Consultation with Dr. {doctorName} on {apptDateStr}";
                var patientBody = BuildPatientEmailBody(
                    patientName, doctorName, apptDateStr, slotStartStr, slotEndStr, graceTimeMinutes, result.RoomUrl);

                await emailService.SendEmailAsync(branchId, patientEmail, patientSubject, patientBody);
                consultation.PatientEmailSent = true;
                Console.WriteLine($"[VIDEO] Patient email sent to {patientEmail}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[VIDEO] Failed to send patient email: {ex.Message}");
                consultation.ErrorMessage = (consultation.ErrorMessage ?? "") + $" | PatEmailErr: {ex.Message}";
            }
        }
        else
        {
            Console.WriteLine($"[VIDEO] No email for PatientId={patientId}, skipping patient email.");
        }

        // ── Step 6: Update email sent flags ─────────────────────────────────
        dbContext.VideoConsultations.Update(consultation);
        await dbContext.SaveChangesAsync();
    }

    // ── Email Body Builders ────────────────────────────────────────────────────

    private static string BuildDoctorEmailBody(
        string doctorName, string patientName, string date,
        string startTime, string endTime, int graceMin, string hostUrl)
    {
        var graceText = graceMin > 0 ? $" (+{graceMin} min grace)" : "";
        return $"""
        <html><body style="font-family:Arial,sans-serif;color:#333;">
        <div style="max-width:600px;margin:0 auto;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden;">
            <div style="background:#1a6fbf;padding:20px;text-align:center;">
                <h2 style="color:#fff;margin:0;">📹 Video Consultation Scheduled</h2>
            </div>
            <div style="padding:24px;">
                <p>Dear <strong>Dr. {doctorName}</strong>,</p>
                <p>A video consultation has been scheduled with the following details:</p>
                <table style="width:100%;border-collapse:collapse;margin:16px 0;">
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Patient</td><td style="padding:8px;">{patientName}</td></tr>
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Date</td><td style="padding:8px;">{date}</td></tr>
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Time</td><td style="padding:8px;">{startTime} to {endTime}{graceText}</td></tr>
                </table>
                <p>Click the button below to join the consultation as <strong>host</strong>:</p>
                <div style="text-align:center;margin:24px 0;">
                    <a href="{hostUrl}" target="_blank"
                       style="background:#1a6fbf;color:#fff;padding:14px 28px;border-radius:6px;text-decoration:none;font-size:16px;font-weight:bold;">
                        🎥 Start Video Consultation
                    </a>
                </div>
                <p style="color:#666;font-size:13px;">As the host, you can admit the patient from the waiting room.</p>
                <hr style="border:none;border-top:1px solid #eee;margin:24px 0;" />
                <p style="color:#999;font-size:12px;">This is an automated notification. Please do not reply to this email.</p>
            </div>
        </div>
        </body></html>
        """;
    }

    private static string BuildPatientEmailBody(
        string patientName, string doctorName, string date,
        string startTime, string endTime, int graceMin, string roomUrl)
    {
        var graceText = graceMin > 0 ? $" (+{graceMin} min grace)" : "";
        return $"""
        <html><body style="font-family:Arial,sans-serif;color:#333;">
        <div style="max-width:600px;margin:0 auto;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden;">
            <div style="background:#0d9e6e;padding:20px;text-align:center;">
                <h2 style="color:#fff;margin:0;">📹 Your Video Consultation</h2>
            </div>
            <div style="padding:24px;">
                <p>Dear <strong>{patientName}</strong>,</p>
                <p>Your video consultation has been confirmed:</p>
                <table style="width:100%;border-collapse:collapse;margin:16px 0;">
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Doctor</td><td style="padding:8px;">Dr. {doctorName}</td></tr>
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Date</td><td style="padding:8px;">{date}</td></tr>
                    <tr><td style="padding:8px;background:#f5f5f5;font-weight:bold;">Time</td><td style="padding:8px;">{startTime} to {endTime}{graceText}</td></tr>
                </table>
                <p>Click the button below to join your appointment:</p>
                <div style="text-align:center;margin:24px 0;">
                    <a href="{roomUrl}" target="_blank"
                       style="background:#0d9e6e;color:#fff;padding:14px 28px;border-radius:6px;text-decoration:none;font-size:16px;font-weight:bold;">
                        🎥 Join Video Consultation
                    </a>
                </div>
                <div style="background:#fff8e1;border-left:4px solid #ffc107;padding:12px;margin:16px 0;border-radius:4px;">
                    <p style="margin:0;font-weight:bold;">📋 Instructions:</p>
                    <ol style="margin:8px 0 0 0;padding-left:20px;">
                        <li>Click the link at your scheduled appointment time.</li>
                        <li>You will enter a waiting room.</li>
                        <li>Click <strong>"Knock"</strong> and the doctor will admit you.</li>
                        <li>No software download required — works directly in your browser.</li>
                    </ol>
                </div>
                <hr style="border:none;border-top:1px solid #eee;margin:24px 0;" />
                <p style="color:#999;font-size:12px;">This is an automated notification. Please do not reply to this email.</p>
            </div>
        </div>
        </body></html>
        """;
    }
}
