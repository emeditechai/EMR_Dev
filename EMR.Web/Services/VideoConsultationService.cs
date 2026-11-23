using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

public class VideoConsultationService(
    ApplicationDbContext dbContext,
    IWherebyService wherebyService,
    IEmailService emailService,
    IWhatsAppService whatsAppService) : IVideoConsultationService
{
    public async Task CreateAndDispatchAsync(
        int opdServiceId, int doctorId, int patientId,
        DateTime appointmentDate, TimeSpan slotStartTime, TimeSpan slotEndTime,
        int graceTimeMinutes, int branchId, string createdBy)
    {
        Console.WriteLine($"[VIDEO] Starting Whereby room creation for OPDServiceId={opdServiceId}, DoctorId={doctorId}, PatientId={patientId}");

        // ── Step 1: Call Whereby API ─────────────────────────────────────────
        WherebyMeetingResult? result = null;
        string? wherebyError = null;
        try
        {
            var companyId = await dbContext.BranchMasters.Where(b => b.BranchId == branchId).Select(b => (int?)b.CompanyId).FirstOrDefaultAsync();
            result = await wherebyService.CreateMeetingAsync(
                patientId, appointmentDate, slotStartTime, slotEndTime, graceTimeMinutes, companyId);   // the booking branch's company
        }
        catch (Exception ex)
        {
            wherebyError = ex.Message;
            Console.WriteLine($"[VIDEO] Whereby API error: {wherebyError}");
        }

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
            consultation.Status           = "Failed";
            consultation.WherebyMeetingId = "ERROR";
            consultation.DoctorHostUrl    = string.Empty;
            consultation.PatientRoomUrl   = string.Empty;
            consultation.MeetingStartDate = DateTime.UtcNow;
            consultation.MeetingEndDate   = DateTime.UtcNow;
            consultation.ErrorMessage     = wherebyError ?? "Whereby API call failed. Check logs.";
            dbContext.VideoConsultations.Add(consultation);
            await dbContext.SaveChangesAsync();
            Console.WriteLine($"[VIDEO] Whereby API failed for OPDServiceId={opdServiceId}. Error: {consultation.ErrorMessage}");
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
        var doctorRow = await con.QueryFirstOrDefaultAsync<(string Name, string? Email, string? Phone)>(
            "SELECT FullName AS Name, EmailId AS Email, PhoneNumber AS Phone FROM DoctorMaster WHERE DoctorId = @DoctorId",
            new { DoctorId = doctorId });

        var patient = await dbContext.PatientMasters.AsNoTracking()
            .FirstOrDefaultAsync(p => p.PatientId == patientId);

        var patientName  = patient != null ? $"{patient.FirstName} {patient.LastName}".Trim() : "Patient";
        var doctorName   = string.IsNullOrWhiteSpace(doctorRow.Name) ? "Doctor" : doctorRow.Name;
        var patientEmail = patient?.EmailId;
        var doctorEmail  = doctorRow.Email;
        var patientPhone = patient?.PhoneNumber;
        var doctorPhone  = doctorRow.Phone;

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

        // ── Step 6: Send WhatsApp Messages ────────────────────────────────────
        var slotString = $"{slotStartStr} to {slotEndStr}";
        await whatsAppService.TriggerVideoConsultationWhatsAppAsync(
            branchId,
            opdServiceId,
            patientPhone ?? string.Empty,
            doctorPhone ?? string.Empty,
            patientName,
            doctorName,
            apptDateStr,
            slotString,
            result.RoomUrl,
            result.HostRoomUrl
        );

        // ── Step 7: Update email sent flags ─────────────────────────────────
        dbContext.VideoConsultations.Update(consultation);
        await dbContext.SaveChangesAsync();
    }

    // ── Email Body Builders ────────────────────────────────────────────────────

    private static string BuildDoctorEmailBody(
        string doctorName, string patientName, string date,
        string startTime, string endTime, int graceMin, string hostUrl)
    {
        static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
        var graceText = graceMin > 0 ? $" (+{graceMin} min grace)" : "";
        return EmailLayout.Wrap(
            EmailLayout.Greeting($"Dr. {doctorName}")
            + EmailLayout.P("A video consultation has been scheduled with the following details:")
            + EmailLayout.Details(("Patient", H(patientName)), ("Date", H(date)), ("Time", H($"{startTime} to {endTime}{graceText}")))
            + EmailLayout.P("Click the button below to join the consultation as <strong>host</strong>:")
            + EmailLayout.Button("Start Video Consultation", hostUrl)
            + EmailLayout.P("As the host, you can admit the patient from the waiting room.", muted: true),
            heading: "Video consultation scheduled");
    }

    private static string BuildPatientEmailBody(
        string patientName, string doctorName, string date,
        string startTime, string endTime, int graceMin, string roomUrl)
    {
        static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
        var graceText = graceMin > 0 ? $" (+{graceMin} min grace)" : "";
        return EmailLayout.Wrap(
            EmailLayout.Greeting(patientName)
            + EmailLayout.P("Your video consultation has been confirmed:")
            + EmailLayout.Details(("Doctor", H($"Dr. {doctorName}")), ("Date", H(date)), ("Time", H($"{startTime} to {endTime}{graceText}")))
            + EmailLayout.P("Click the button below to join your appointment:")
            + EmailLayout.Button("Join Video Consultation", roomUrl)
            + EmailLayout.Callout(@"<strong>How to join</strong>
                <ol style=""margin:8px 0 0;padding-left:20px;"">
                    <li>Click the link at your scheduled appointment time.</li>
                    <li>You will enter a waiting room.</li>
                    <li>Click <strong>""Knock""</strong> and the doctor will admit you.</li>
                    <li>No software download required - works directly in your browser.</li>
                </ol>"),
            heading: "Your video consultation");
    }
}
