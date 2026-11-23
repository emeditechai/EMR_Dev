using System.Data;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Common;

namespace EMR.Api.Services;

/// <summary>A bill as a PDF for a booking message: its file name and bytes (phase 4: IPatientBillPdfs).</summary>
public sealed record BillPdf(string FileName, byte[] Bytes);

/// <summary>Makes a LAB or OPD bill PDF for the booking messages; registered once the bill PDFs are drawn in EMR.Api.</summary>
public interface IPatientBillPdfs
{
    Task<BillPdf?> LabBillAsync(int labOrderId);
    Task<BillPdf?> OpdBillAsync(int opdServiceId);
}

/// <summary>
/// The booking confirmations of the patient app, as EMR.Web sends them for a counter booking (LabBookingNotifier,
/// OpdBookingNotifier, WhatsAppService.TriggerLab/OpdBillWhatsAppAsync): WhatsApp with the branch's message template and
/// the bill attached, and e-mail when the patient has one and the branch sends them. In the background, so a slow or failed
/// send never holds up the booking.
/// </summary>
public interface IPatientAppNotices
{
    void QueueLabBooking(int branchId, int labOrderId);
    void QueueOpdBooking(int branchId, int opdServiceId);
}

public sealed class PatientAppNotices(IServiceScopeFactory scopeFactory, ILogger<PatientAppNotices> logger) : IPatientAppNotices
{
    private sealed class WaSettings
    {
        public bool IsEnabled { get; set; }
        public bool LabNotificationEnabled { get; set; }
        public bool OpdNotificationEnabled { get; set; }
        public string? LabMessageTemplate { get; set; }
        public string? OpdMessageTemplate { get; set; }
    }

    private sealed class Hospital
    {
        public string? HospitalName { get; set; }
        public string? Address { get; set; }
        public bool EmailNotificationRequired { get; set; }
        public bool LabEmailNotificationRequired { get; set; }
    }

    // the branch's WhatsApp configuration, else the company's default one (its HO branch's first) - WhatsAppService.GetActiveConfigAsync
    private static Task<WaSettings?> WaSettingsAsync(IDbConnection con, int branchId) =>
        con.QueryFirstOrDefaultAsync<WaSettings?>(@"
            SELECT TOP 1 w.IsEnabled, w.LabNotificationEnabled, w.OpdNotificationEnabled, w.LabMessageTemplate, w.OpdMessageTemplate
              FROM dbo.WhatsAppConfiguration w
             WHERE w.IsActive = 1 AND (w.BranchId = @branchId
                   OR (NOT EXISTS (SELECT 1 FROM dbo.WhatsAppConfiguration x WHERE x.BranchId = @branchId AND x.IsActive = 1)
                       AND w.IsDefault = 1 AND w.CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @branchId)))
             ORDER BY CASE WHEN w.BranchId = @branchId THEN 0 ELSE 1 END,
                      CASE WHEN EXISTS (SELECT 1 FROM dbo.Branchmaster b WHERE b.BranchID = w.BranchId AND b.IsHOBranch = 1) THEN 0 ELSE 1 END,
                      w.BranchId", new { branchId });

    private static Task<Hospital?> HospitalAsync(IDbConnection con, int branchId, bool activeOnly) =>
        con.QueryFirstOrDefaultAsync<Hospital?>(
            "SELECT TOP 1 HotelName AS HospitalName, Address, EmailNotificationRequired, LabEmailNotificationRequired FROM dbo.HospitalSettings WHERE BranchId = @branchId"
            + (activeOnly ? " AND IsActive = 1" : ""), new { branchId });

    public void QueueLabBooking(int branchId, int labOrderId) => Run($"LAB order {labOrderId}", async sp =>
    {
        using var con = sp.GetRequiredService<IDbConnectionFactory>().CreateConnection();
        var order = await con.QueryFirstOrDefaultAsync<(int BranchId, int PatientId, string? BillNo, string? TokenNo, decimal? TotalAmount, bool IsB2B)>(
            "SELECT BranchId, PatientId, BillNo, TokenNo, TotalAmount, CAST(ISNULL(IsB2B, 0) AS BIT) FROM dbo.LabOrder WHERE LabOrderId = @Id", new { Id = labOrderId });
        if (order.PatientId <= 0) return;
        if (order.BranchId > 0) branchId = order.BranchId;
        var patient = await con.QueryFirstOrDefaultAsync<(string? FirstName, string? LastName, string? PhoneNumber, string? EmailId)>(
            "SELECT FirstName, LastName, PhoneNumber, EmailId FROM dbo.PatientMaster WHERE PatientId = @Id", new { Id = order.PatientId });
        var name = $"{patient.FirstName} {patient.LastName}".Trim();
        var pdf = await BillPdfAsync(sp, p => p.LabBillAsync(labOrderId), $"LAB order {labOrderId}");

        // 1. WhatsApp: the branch's LAB template, without test names, the bill attached
        var wa = await WaSettingsAsync(con, branchId);
        if (wa is { IsEnabled: true, LabNotificationEnabled: true } && !string.IsNullOrWhiteSpace(patient.PhoneNumber))
        {
            var hospital = await HospitalAsync(con, branchId, false);
            var template = string.IsNullOrWhiteSpace(wa.LabMessageTemplate)
                ? "Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!"
                : wa.LabMessageTemplate;
            template = Regex.Replace(template, @"Investigations:\s*\{TestNames\}\.?\s*", "", RegexOptions.IgnoreCase).Replace("{TestNames}", "").Trim();
            var text = template.Replace("{PatientName}", name).Replace("{HospitalName}", hospital?.HospitalName ?? "Our Diagnostic Lab")
                .Replace("{BillNo}", order.BillNo ?? "").Replace("{TokenNo}", order.TokenNo ?? "—").Replace("{Amount}", (order.TotalAmount ?? 0m).ToString("N2")).Trim();
            await SendWhatsAppAsync(sp, branchId, patient.PhoneNumber, text, "LAB", labOrderId, pdf,
                $"Lab_Bill_{Safe(order.BillNo ?? $"Bill_{labOrderId}")}.pdf");
        }

        // 2. e-mail, when the patient has one and the branch sends LAB e-mails
        if (!string.IsNullOrWhiteSpace(patient.EmailId))
        {
            var hs = await HospitalAsync(con, branchId, true);
            if (hs is { LabEmailNotificationRequired: true })
            {
                var subject = $"Your Lab Order Bill [{order.BillNo}] - {hs.HospitalName}";
                var body = LabBillEmail.Body(hs.HospitalName, name, order.BillNo, hs.Address);
                await sp.GetRequiredService<ISmtpEmailSender>().SendAsync(branchId, patient.EmailId, subject, body,
                    pdf == null ? null : [new EmailAttachment($"Lab_Bill_{Safe(order.BillNo ?? "")}.pdf", "application/pdf", pdf.Bytes)]);
            }
        }
    });

    public void QueueOpdBooking(int branchId, int opdServiceId) => Run($"OPD visit {opdServiceId}", async sp =>
    {
        using var con = sp.GetRequiredService<IDbConnectionFactory>().CreateConnection();
        var b = await con.QueryFirstOrDefaultAsync<(int? BranchId, int PatientId, int? ConsultingDoctorId, string? OPDBillNo, string? TokenNo, decimal? TotalAmount, DateTime VisitDate, TimeSpan? AppointmentTime)>(
            "SELECT BranchId, PatientId, ConsultingDoctorId, OPDBillNo, TokenNo, TotalAmount, VisitDate, AppointmentTime FROM dbo.PatientOPDService WHERE OPDServiceId = @Id",
            new { Id = opdServiceId });
        if (b.PatientId <= 0) return;
        if (b.BranchId is > 0) branchId = b.BranchId.Value;
        var patient = await con.QueryFirstOrDefaultAsync<(string? FirstName, string? LastName, string? PhoneNumber, string? EmailId)>(
            "SELECT FirstName, LastName, PhoneNumber, EmailId FROM dbo.PatientMaster WHERE PatientId = @Id", new { Id = b.PatientId });
        var doctor = b.ConsultingDoctorId is int d
            ? await con.QueryFirstOrDefaultAsync<string?>("SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @d", new { d }) : null;
        var hospital = await HospitalAsync(con, branchId, false);
        var pdf = await BillPdfAsync(sp, p => p.OpdBillAsync(opdServiceId), $"OPD visit {opdServiceId}");

        // 1. WhatsApp: the branch's OPD template, the bill attached
        var wa = await WaSettingsAsync(con, branchId);
        if (wa is { IsEnabled: true, OpdNotificationEnabled: true } && !string.IsNullOrWhiteSpace(patient.PhoneNumber))
        {
            var template = string.IsNullOrWhiteSpace(wa.OpdMessageTemplate)
                ? "Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!"
                : wa.OpdMessageTemplate;
            var text = template.Replace("{PatientName}", $"{patient.FirstName} {patient.LastName}".Trim())
                .Replace("{HospitalName}", hospital?.HospitalName ?? "Our Clinic").Replace("{BillNo}", b.OPDBillNo ?? "")
                .Replace("{TokenNo}", b.TokenNo ?? "—").Replace("{DoctorName}", string.IsNullOrWhiteSpace(doctor) ? "Attending Physician" : doctor)
                .Replace("{Amount}", (b.TotalAmount ?? 0m).ToString("N2")).Trim();
            await SendWhatsAppAsync(sp, branchId, patient.PhoneNumber, text, "OPD", opdServiceId, pdf,
                $"OPD_Bill_{Safe(b.OPDBillNo ?? $"OPD_{opdServiceId}")}.pdf");
        }

        // 2. e-mail: the branch's "Booking Confirmation" template (Utility > Email Templates)
        if (!string.IsNullOrWhiteSpace(patient.EmailId) && hospital is { EmailNotificationRequired: true })
        {
            var template = await con.QueryFirstOrDefaultAsync<(string Subject, string HtmlBody)?>(
                "SELECT TOP 1 Subject, HtmlBody FROM dbo.EmailTemplates WHERE BranchId = @branchId AND TemplateName = 'Booking Confirmation' AND IsActive = 1",
                new { branchId });
            if (template is { } t)
            {
                var slot = b.AppointmentTime.HasValue ? DateTime.Today.Add(b.AppointmentTime.Value).ToString("hh:mm tt") : "N/A";
                string Fill(string text) => text
                    .Replace("{{PatientName}}", $"{patient.FirstName} {patient.LastName}").Replace("{{DoctorName}}", doctor ?? "")
                    .Replace("{{TokenNo}}", b.TokenNo ?? "Pending").Replace("{{TotalAmount}}", b.TotalAmount?.ToString("0.00") ?? "0.00")
                    .Replace("{{VisitDate}}", b.VisitDate.ToString("dd-MMM-yyyy")).Replace("{{SlotTime}}", slot)
                    .Replace("{{HospitalName}}", hospital.HospitalName ?? "Our Hospital");
                await sp.GetRequiredService<ISmtpEmailSender>().SendAsync(branchId, patient.EmailId, Fill(t.Subject), Fill(t.HtmlBody),
                    pdf == null ? null : [new EmailAttachment(pdf.FileName, "application/pdf", pdf.Bytes)]);
            }
        }
    });

    private async Task SendWhatsAppAsync(IServiceProvider sp, int branchId, string phone, string text, string module, int refId, BillPdf? pdf, string fileName)
    {
        var wa = sp.GetRequiredService<IWhatsAppTextSender>();
        string? url = pdf == null ? null : await wa.UploadMediaAsync(pdf.Bytes, "application/pdf", branchId);
        await wa.SendDocumentAsync(branchId, phone, text, module, refId, url, url == null ? null : fileName);
    }

    private async Task<BillPdf?> BillPdfAsync(IServiceProvider sp, Func<IPatientBillPdfs, Task<BillPdf?>> make, string what)
    {
        if (sp.GetService<IPatientBillPdfs>() is not { } pdfs) return null;
        try { return await make(pdfs); }
        catch (Exception ex) { logger.LogWarning(ex, "[PATIENT-APP] Bill PDF of {What} could not be made; the message goes without it", what); return null; }
    }

    private static string Safe(string billNo) => billNo.Replace("/", "_").Replace("\\", "_");

    private void Run(string what, Func<IServiceProvider, Task> work) => _ = Task.Run(async () =>
    {
        try
        {
            using var scope = scopeFactory.CreateScope();
            await work(scope.ServiceProvider);
        }
        catch (Exception ex) { logger.LogError(ex, "[PATIENT-APP] Booking notice for {What} failed", what); }
    });
}
