using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class VideoConfigController(
    ApplicationDbContext dbContext,
    IWherebyService wherebyService,
    IAuditLogService auditLogService) : Controller
{
    // ── Index: List all config rows ────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var configs = await dbContext.VideoSystemConfigs
            .OrderBy(c => c.ConfigKey)
            .ToListAsync();

        ViewData["Title"] = "Video Consultation Config";
        return View(configs);
    }

    // ── Save / Upsert a config value ──────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] VideoConfigSaveRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.ConfigKey) || req.ConfigValue == null)
            return Json(new { success = false, message = "Invalid data." });

        if (req.ConfigKey == "WherebyApiKey" && req.ConfigValue.Contains(" "))
            return Json(new { success = false, message = "API Key cannot contain spaces. Please ensure you haven't accidentally pasted the URL." });

        var existing = await dbContext.VideoSystemConfigs
            .FirstOrDefaultAsync(c => c.ConfigKey == req.ConfigKey);

        if (existing == null)
        {
            dbContext.VideoSystemConfigs.Add(new VideoSystemConfig
            {
                ConfigKey           = req.ConfigKey.Trim(),
                ConfigValue         = req.ConfigValue.Trim(),
                MeetingCreationUrl  = req.MeetingCreationUrl?.Trim(),
                IsActive            = req.IsActive,
                CreatedDate         = DateTime.Now,
                ModifiedDate        = DateTime.Now,
                ModifiedBy          = User.Identity?.Name
            });
        }
        else
        {
            existing.ConfigValue        = req.ConfigValue.Trim();
            existing.MeetingCreationUrl = req.MeetingCreationUrl?.Trim();
            existing.IsActive           = req.IsActive;
            existing.ModifiedDate       = DateTime.Now;
            existing.ModifiedBy         = User.Identity?.Name;
        }

        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("Settings", "VideoConfig.Save",
            $"Updated config key: {req.ConfigKey}");

        return Json(new { success = true, message = $"Config '{req.ConfigKey}' saved." });
    }

    // ── Add new config row ────────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> AddConfig([FromBody] VideoConfigSaveRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.ConfigKey) || req.ConfigValue == null)
            return Json(new { success = false, message = "Invalid data." });

        if (req.ConfigKey == "WherebyApiKey" && req.ConfigValue.Contains(" "))
            return Json(new { success = false, message = "API Key cannot contain spaces. Please ensure you haven't accidentally pasted the URL." });

        var exists = await dbContext.VideoSystemConfigs.AnyAsync(c => c.ConfigKey == req.ConfigKey.Trim());
        if (exists)
            return Json(new { success = false, message = $"Config key '{req.ConfigKey}' already exists." });

        dbContext.VideoSystemConfigs.Add(new VideoSystemConfig
        {
            ConfigKey          = req.ConfigKey.Trim(),
            ConfigValue        = req.ConfigValue.Trim(),
            MeetingCreationUrl = req.MeetingCreationUrl?.Trim(),
            IsActive           = req.IsActive,
            CreatedDate        = DateTime.Now,
            ModifiedDate       = DateTime.Now,
            ModifiedBy         = User.Identity?.Name
        });
        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("Settings", "VideoConfig.Add", $"Added config key: {req.ConfigKey}");
        return Json(new { success = true });
    }

    // ── Delete a config row ───────────────────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete([FromBody] int configId)
    {
        var config = await dbContext.VideoSystemConfigs.FindAsync(configId);
        if (config == null) return Json(new { success = false, message = "Not found." });

        dbContext.VideoSystemConfigs.Remove(config);
        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("Settings", "VideoConfig.Delete", $"Deleted config: {config.ConfigKey}");
        return Json(new { success = true });
    }

    // ── Test connection: validates the API key against Whereby ────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> TestConnection()
    {
        try
        {
            var apiKey = await dbContext.VideoSystemConfigs
                .Where(c => c.ConfigKey == "WherebyApiKey" && c.IsActive)
                .Select(c => c.ConfigValue)
                .FirstOrDefaultAsync();

            if (string.IsNullOrWhiteSpace(apiKey))
                return Json(new { success = false, message = "WherebyApiKey not configured." });

            // Create a test meeting with 5-minute window
            var testResult = await wherebyService.CreateMeetingAsync(
                patientId        : 0,
                appointmentDate  : DateTime.Today,
                slotStartTime    : TimeSpan.FromHours(12),
                slotEndTime      : TimeSpan.FromHours(12).Add(TimeSpan.FromMinutes(5)),
                graceTimeMinutes : 0);

            if (testResult != null)
                return Json(new { success = true, message = $"✅ Connection successful! Meeting ID: {testResult.MeetingId}" });
            else
                return Json(new { success = false, message = "API key test failed. Check the key and try again." });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = $"Error: {ex.Message}" });
        }
    }

    // ── Get Failed Video Bookings for admin retrigger panel ───────────────────
    [HttpGet]
    public async Task<IActionResult> GetFailedVideoBookings()
    {
        try
        {
            using var con = dbContext.Database.GetDbConnection();
            var items = await con.QueryAsync<dynamic>(@"
                -- Case 1: Failed video consultation records
                SELECT 
                    vc.ConsultationId,
                    pos.OPDServiceId,
                    ISNULL(vc.ErrorMessage, 'Whereby API call failed') AS ErrorMessage,
                    vc.CreatedDate,
                    pos.OPDBillNo AS OpdBillNo,
                    pos.VisitDate,
                    LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
                    ISNULL(d.FullName, 'Unknown Doctor') AS DoctorName,
                    'Failed' AS IssueType
                FROM tbl_VideoConsultation vc
                JOIN PatientOPDService pos ON pos.OPDServiceId = vc.OPDServiceId
                JOIN PatientMaster p ON p.PatientId = pos.PatientId
                LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
                WHERE vc.Status = 'Failed'

                UNION ALL

                -- Case 2: Video OPDs that are fully paid but have NO consultation record at all
                SELECT 
                    NULL AS ConsultationId,
                    pos.OPDServiceId,
                    'Video room never created (trigger did not fire)' AS ErrorMessage,
                    pos.ModifiedDate AS CreatedDate,
                    pos.OPDBillNo AS OpdBillNo,
                    pos.VisitDate,
                    LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
                    ISNULL(d.FullName, 'Unknown Doctor') AS DoctorName,
                    'NeverCreated' AS IssueType
                FROM PatientOPDService pos
                JOIN PatientMaster p ON p.PatientId = pos.PatientId
                LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
                WHERE pos.IsActive = 1
                  AND pos.Status IN ('Consulting', 'Completed', 'Skipped')
                  AND EXISTS (
                      SELECT 1 FROM PatientOPDServiceItem i
                      JOIN ServiceMaster sm ON sm.ServiceId = i.ServiceId
                      WHERE i.OPDServiceId = pos.OPDServiceId AND sm.ConsultingType = 'Video' AND i.IsActive = 1
                  )
                  AND EXISTS (
                      SELECT 1 FROM PaymentHeader ph
                      WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = pos.OPDServiceId AND ph.PaymentStatus = 'P' AND ph.IsActive = 1
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM tbl_VideoConsultation vc2
                      WHERE vc2.OPDServiceId = pos.OPDServiceId
                  )

                ORDER BY VisitDate DESC, OPDServiceId DESC");

            var result = items.Select(i => new
            {
                ConsultationId = (int?)i.ConsultationId,
                OpdServiceId   = (int)i.OPDServiceId,
                OpdBillNo      = (string?)i.OpdBillNo,
                VisitDate      = ((DateTime)i.VisitDate).ToString("dd-MMM-yyyy"),
                PatientName    = (string)i.PatientName,
                DoctorName     = (string)i.DoctorName,
                ErrorMessage   = (string?)i.ErrorMessage,
                IssueType      = (string)i.IssueType
            }).ToList();

            return Json(new { success = true, items = result });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, message = ex.Message, items = Array.Empty<object>() });
        }
    }
}

public class VideoConfigSaveRequest
{
    public string ConfigKey { get; set; } = string.Empty;
    public string ConfigValue { get; set; } = string.Empty;
    public string? MeetingCreationUrl { get; set; }
    public bool IsActive { get; set; } = true;
}
