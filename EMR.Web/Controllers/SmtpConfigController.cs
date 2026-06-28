using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class SmtpConfigController(
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    IEmailService emailService,
    IDataProtectionProvider dataProtectionProvider) : Controller
{
    private const string ProtectorPurpose = "SmtpPassword.v1";

    // ── INDEX ─────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found. Please select a branch first.";
            return RedirectToAction("Index", "Dashboard");
        }

        var configs = await dbContext.SmtpEmailConfigurations
            .Where(x => x.BranchId == branchId.Value && x.IsActive)
            .OrderByDescending(x => x.IsDefault)
            .ThenByDescending(x => x.CreatedDate)
            .Select(x => new SmtpConfigListItem
            {
                Id = x.Id,
                ConfigName = x.ConfigName,
                ProviderType = x.ProviderType,
                SmtpHost = x.SmtpHost,
                SmtpPort = x.SmtpPort,
                UseSsl = x.UseSsl,
                UseStartTls = x.UseStartTls,
                SenderEmail = x.SenderEmail,
                SenderDisplayName = x.SenderDisplayName,
                IsDefault = x.IsDefault,
                IsActive = x.IsActive,
                LastTestedDate = x.LastTestedDate,
                LastTestResult = x.LastTestResult,
                CreatedDate = x.CreatedDate,
                ModifiedDate = x.ModifiedDate
            })
            .ToListAsync();

        ViewBag.BranchName = (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName ?? "—";
        return View(configs);
    }

    // ── CREATE ────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found.";
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var model = new SmtpConfigFormViewModel
        {
            BranchId = branchId.Value,
            BranchName = branch?.BranchName ?? string.Empty,
            IsEdit = false
        };
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(SmtpConfigFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return RedirectToAction("Index", "Dashboard");

        model.BranchId = branchId.Value;

        if (string.IsNullOrWhiteSpace(model.Password))
            ModelState.AddModelError(nameof(model.Password), "Password is required for new configuration.");

        if (!ModelState.IsValid)
        {
            var br = await dbContext.BranchMasters.FindAsync(branchId.Value);
            model.BranchName = br?.BranchName ?? string.Empty;
            return View(model);
        }

        var userId = User.GetUserId();
        var protector = dataProtectionProvider.CreateProtector(ProtectorPurpose);

        // If setting as default, clear other defaults
        if (model.IsDefault)
        {
            await ClearDefaultsAsync(branchId.Value);
        }

        var entity = new SmtpEmailConfiguration
        {
            BranchId = branchId.Value,
            ConfigName = model.ConfigName,
            ProviderType = model.ProviderType,
            SmtpHost = model.SmtpHost,
            SmtpPort = model.SmtpPort,
            UseSsl = model.UseSsl,
            UseStartTls = model.UseStartTls,
            SenderEmail = model.SenderEmail,
            SenderDisplayName = model.SenderDisplayName,
            Username = model.Username,
            PasswordEncrypted = protector.Protect(model.Password!),
            IsDefault = model.IsDefault,
            IsActive = true,
            CreatedBy = userId,
            CreatedDate = DateTime.Now
        };

        dbContext.SmtpEmailConfigurations.Add(entity);
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Create", "SmtpConfig",
            $"SMTP config '{model.ConfigName}' created for branch {branchId}", userId, branchId);

        TempData["Success"] = $"SMTP configuration \"{model.ConfigName}\" created successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── EDIT ──────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found.";
            return RedirectToAction("Index", "Dashboard");
        }

        var entity = await dbContext.SmtpEmailConfigurations
            .FirstOrDefaultAsync(x => x.Id == id && x.BranchId == branchId.Value);

        if (entity is null)
        {
            TempData["Error"] = "Configuration not found.";
            return RedirectToAction(nameof(Index));
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var model = new SmtpConfigFormViewModel
        {
            Id = entity.Id,
            BranchId = entity.BranchId,
            BranchName = branch?.BranchName ?? string.Empty,
            ConfigName = entity.ConfigName,
            ProviderType = entity.ProviderType,
            SmtpHost = entity.SmtpHost,
            SmtpPort = entity.SmtpPort,
            UseSsl = entity.UseSsl,
            UseStartTls = entity.UseStartTls,
            SenderEmail = entity.SenderEmail,
            SenderDisplayName = entity.SenderDisplayName,
            Username = entity.Username,
            Password = null, // Never send password back
            IsDefault = entity.IsDefault,
            IsActive = entity.IsActive,
            IsEdit = true
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, SmtpConfigFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return RedirectToAction("Index", "Dashboard");

        model.BranchId = branchId.Value;
        model.IsEdit = true;

        // On edit, password is optional (blank = keep existing)
        if (string.IsNullOrWhiteSpace(model.Password))
            ModelState.Remove(nameof(model.Password));

        if (!ModelState.IsValid)
        {
            var br = await dbContext.BranchMasters.FindAsync(branchId.Value);
            model.BranchName = br?.BranchName ?? string.Empty;
            return View(model);
        }

        var entity = await dbContext.SmtpEmailConfigurations
            .FirstOrDefaultAsync(x => x.Id == id && x.BranchId == branchId.Value);

        if (entity is null)
        {
            TempData["Error"] = "Configuration not found.";
            return RedirectToAction(nameof(Index));
        }

        var userId = User.GetUserId();

        entity.ConfigName = model.ConfigName;
        entity.ProviderType = model.ProviderType;
        entity.SmtpHost = model.SmtpHost;
        entity.SmtpPort = model.SmtpPort;
        entity.UseSsl = model.UseSsl;
        entity.UseStartTls = model.UseStartTls;
        entity.SenderEmail = model.SenderEmail;
        entity.SenderDisplayName = model.SenderDisplayName;
        entity.Username = model.Username;
        entity.IsActive = model.IsActive;
        entity.ModifiedBy = userId;
        entity.ModifiedDate = DateTime.Now;

        // Update password only if a new one is provided
        if (!string.IsNullOrWhiteSpace(model.Password))
        {
            var protector = dataProtectionProvider.CreateProtector(ProtectorPurpose);
            entity.PasswordEncrypted = protector.Protect(model.Password);
        }

        // Handle default toggle
        if (model.IsDefault && !entity.IsDefault)
        {
            await ClearDefaultsAsync(branchId.Value);
        }
        entity.IsDefault = model.IsDefault;

        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Update", "SmtpConfig",
            $"SMTP config '{model.ConfigName}' (ID:{id}) updated for branch {branchId}", userId, branchId);

        TempData["Success"] = $"SMTP configuration \"{model.ConfigName}\" updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── DELETE (Soft Delete) ──────────────────────────────────────────────────

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return Json(new { success = false, message = "No active branch." });

        var entity = await dbContext.SmtpEmailConfigurations
            .FirstOrDefaultAsync(x => x.Id == id && x.BranchId == branchId.Value);

        if (entity is null)
            return Json(new { success = false, message = "Configuration not found." });

        entity.IsActive = false;
        entity.ModifiedBy = User.GetUserId();
        entity.ModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Delete", "SmtpConfig",
            $"SMTP config '{entity.ConfigName}' (ID:{id}) deleted for branch {branchId}", User.GetUserId(), branchId);

        return Json(new { success = true, message = $"Configuration \"{entity.ConfigName}\" deleted." });
    }

    // ── SET DEFAULT ───────────────────────────────────────────────────────────

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SetDefault(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return Json(new { success = false, message = "No active branch." });

        var entity = await dbContext.SmtpEmailConfigurations
            .FirstOrDefaultAsync(x => x.Id == id && x.BranchId == branchId.Value && x.IsActive);

        if (entity is null)
            return Json(new { success = false, message = "Configuration not found." });

        await ClearDefaultsAsync(branchId.Value);
        entity.IsDefault = true;
        entity.ModifiedBy = User.GetUserId();
        entity.ModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Update", "SmtpConfig",
            $"SMTP config '{entity.ConfigName}' (ID:{id}) set as default for branch {branchId}", User.GetUserId(), branchId);

        return Json(new { success = true, message = $"\"{entity.ConfigName}\" set as default." });
    }

    // ── TEST EMAIL (AJAX) ─────────────────────────────────────────────────────

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TestEmail([FromBody] SmtpTestEmailViewModel model)
    {
        if (!ModelState.IsValid)
        {
            var errors = ModelState.Values.SelectMany(v => v.Errors).Select(e => e.ErrorMessage);
            return Json(new { success = false, message = string.Join("; ", errors) });
        }

        var (success, message) = await emailService.SendTestEmailAsync(
            model.ConfigId, model.RecipientEmail, model.Subject, model.Body);

        return Json(new { success, message });
    }

    // ── HELPERS ────────────────────────────────────────────────────────────────

    private async Task ClearDefaultsAsync(int branchId)
    {
        var existing = await dbContext.SmtpEmailConfigurations
            .Where(x => x.BranchId == branchId && x.IsDefault)
            .ToListAsync();

        foreach (var cfg in existing)
            cfg.IsDefault = false;
    }
}
