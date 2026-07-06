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
}

public class VideoConfigSaveRequest
{
    public string ConfigKey { get; set; } = string.Empty;
    public string ConfigValue { get; set; } = string.Empty;
    public string? MeetingCreationUrl { get; set; }
    public bool IsActive { get; set; } = true;
}
