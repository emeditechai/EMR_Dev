using System;
using System.Linq;
using System.Security.Claims;
using System.Threading.Tasks;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class WhatsAppConfigController(
    ApplicationDbContext dbContext,
    IWhatsAppService whatsAppService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found. Please select a branch first.";
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var branchName = branch?.BranchName ?? "Current Branch";

        var config = await dbContext.WhatsAppConfigurations
            .FirstOrDefaultAsync(c => c.BranchId == branchId.Value && c.IsActive);

        // Fallback to default config if branch doesn't have its own
        if (config == null)
        {
            var defaultConfig = await dbContext.WhatsAppConfigurations
                .FirstOrDefaultAsync(c => c.IsDefault && c.IsActive);

            if (defaultConfig != null)
            {
                config = new WhatsAppConfiguration
                {
                    BranchId = branchId.Value,
                    CompanyId = User.GetCompanyId(),
                    ConfigName = $"{branchName} WhatsApp Config",
                    ApiUrl = defaultConfig.ApiUrl,
                    AuthHeaderKey = defaultConfig.AuthHeaderKey,
                    ApiKey = defaultConfig.ApiKey,
                    DefaultCountryCode = defaultConfig.DefaultCountryCode,
                    IsEnabled = defaultConfig.IsEnabled,
                    OpdNotificationEnabled = defaultConfig.OpdNotificationEnabled,
                    LabNotificationEnabled = defaultConfig.LabNotificationEnabled,
                    OpdMessageTemplate = defaultConfig.OpdMessageTemplate,
                    LabMessageTemplate = defaultConfig.LabMessageTemplate,
                    IsDefault = false,
                    IsActive = true
                };
            }
        }

        var recentLogs = await dbContext.WhatsAppLogs
            .Where(l => l.BranchId == branchId.Value)
            .OrderByDescending(l => l.SentDate)
            .Take(25)
            .ToListAsync();

        var isHO = await CheckIsHOBranchAsync(branchId.Value);
        var targetBranches = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>();

        if (isHO)
        {
            var companyId = User.GetCompanyId();
            targetBranches = await dbContext.BranchMasters
                .Where(b => b.BranchId != branchId.Value && b.IsActive && (companyId <= 0 || b.CompanyId == companyId))
                .OrderBy(b => b.BranchName)
                .Select(b => new Microsoft.AspNetCore.Mvc.Rendering.SelectListItem
                {
                    Value = b.BranchId.ToString(),
                    Text = $"{b.BranchName} ({b.BranchCode})"
                })
                .ToListAsync();
        }

        var viewModel = new WhatsAppConfigViewModel
        {
            Id = config?.Id ?? 0,
            BranchId = branchId.Value,
            BranchName = branchName,
            IsHOBranch = isHO,
            TargetBranches = targetBranches,
            ConfigName = config?.ConfigName ?? $"{branchName} WhatsApp Config",
            ApiUrl = config?.ApiUrl ?? "https://wasenderapi.com/api/send-message",
            AuthHeaderKey = config?.AuthHeaderKey ?? "Authorization",
            ApiKey = config?.ApiKey ?? string.Empty,
            DefaultCountryCode = config?.DefaultCountryCode ?? "+91",
            SenderPhone = config?.SenderPhone,
            IsEnabled = config?.IsEnabled ?? true,
            OpdNotificationEnabled = config?.OpdNotificationEnabled ?? true,
            LabNotificationEnabled = config?.LabNotificationEnabled ?? true,
            OpdMessageTemplate = config?.OpdMessageTemplate ?? "Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Wish you a speedy recovery!",
            LabMessageTemplate = config?.LabMessageTemplate ?? "Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!",
            LastTestedDate = config?.LastTestedDate,
            LastTestResult = config?.LastTestResult,
            RecentLogs = recentLogs
        };

        ViewData["Title"] = "WhatsApp Configuration";
        return View(viewModel);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(WhatsAppConfigViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Session expired or invalid branch.";
            return RedirectToAction("Index");
        }

        if (!ModelState.IsValid)
        {
            var isHO = await CheckIsHOBranchAsync(branchId.Value);
            model.IsHOBranch = isHO;
            if (isHO)
            {
                var companyId = User.GetCompanyId();
                model.TargetBranches = await dbContext.BranchMasters
                    .Where(b => b.BranchId != branchId.Value && b.IsActive && (companyId <= 0 || b.CompanyId == companyId))
                    .OrderBy(b => b.BranchName)
                    .Select(b => new Microsoft.AspNetCore.Mvc.Rendering.SelectListItem
                    {
                        Value = b.BranchId.ToString(),
                        Text = $"{b.BranchName} ({b.BranchCode})"
                    })
                    .ToListAsync();
            }

            model.RecentLogs = await dbContext.WhatsAppLogs
                .Where(l => l.BranchId == branchId.Value)
                .OrderByDescending(l => l.SentDate)
                .Take(25)
                .ToListAsync();
            return View("Index", model);
        }

        var config = await dbContext.WhatsAppConfigurations
            .FirstOrDefaultAsync(c => c.BranchId == branchId.Value);

        if (config == null)
        {
            config = new WhatsAppConfiguration
            {
                BranchId = branchId.Value,
                CompanyId = User.GetCompanyId(),
                CreatedBy = User.Identity?.Name,
                CreatedDate = DateTime.Now
            };
            dbContext.WhatsAppConfigurations.Add(config);
        }

        config.ConfigName = model.ConfigName.Trim();
        config.ApiUrl = model.ApiUrl.Trim();
        config.AuthHeaderKey = string.IsNullOrWhiteSpace(model.AuthHeaderKey) ? "Authorization" : model.AuthHeaderKey.Trim();
        config.ApiKey = model.ApiKey.Trim();
        config.DefaultCountryCode = string.IsNullOrWhiteSpace(model.DefaultCountryCode) ? "+91" : model.DefaultCountryCode.Trim();
        config.SenderPhone = model.SenderPhone?.Trim();
        config.IsEnabled = model.IsEnabled;
        config.OpdNotificationEnabled = model.OpdNotificationEnabled;
        config.LabNotificationEnabled = model.LabNotificationEnabled;
        config.OpdMessageTemplate = model.OpdMessageTemplate.Trim();
        config.LabMessageTemplate = model.LabMessageTemplate.Trim();
        config.IsActive = true;
        config.ModifiedBy = User.Identity?.Name;
        config.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();

        TempData["Success"] = "WhatsApp configuration saved successfully!";
        return RedirectToAction("Index");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CopyToBranch(int targetBranchId, bool copyToAll = false)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Session expired or invalid branch.";
            return RedirectToAction("Index");
        }

        // 1. Validation: Only HO branch can copy configuration to target branches
        var isHO = await CheckIsHOBranchAsync(branchId.Value);
        if (!isHO)
        {
            TempData["Error"] = "Unauthorized: Only the Head Office (HO) branch is allowed to copy configuration to target branches.";
            return RedirectToAction("Index");
        }

        // 2. Fetch source HO configuration
        var hoConfig = await dbContext.WhatsAppConfigurations
            .FirstOrDefaultAsync(c => c.BranchId == branchId.Value && c.IsActive);

        if (hoConfig == null)
        {
            TempData["Error"] = "Head Office WhatsApp configuration not found or inactive. Please configure and save HO settings first.";
            return RedirectToAction("Index");
        }

        // 3. Determine target branches
        var companyId = User.GetCompanyId();
        List<BranchMaster> targetBranches;

        if (copyToAll || targetBranchId <= 0)
        {
            targetBranches = await dbContext.BranchMasters
                .Where(b => b.BranchId != branchId.Value && b.IsActive && (companyId <= 0 || b.CompanyId == companyId))
                .ToListAsync();
        }
        else
        {
            var target = await dbContext.BranchMasters.FirstOrDefaultAsync(b => b.BranchId == targetBranchId && b.IsActive);
            if (target == null)
            {
                TempData["Error"] = "Selected target branch does not exist or is inactive.";
                return RedirectToAction("Index");
            }
            targetBranches = new List<BranchMaster> { target };
        }

        if (!targetBranches.Any())
        {
            TempData["Error"] = "No target branches found to copy configuration to.";
            return RedirectToAction("Index");
        }

        int copiedCount = 0;
        foreach (var target in targetBranches)
        {
            var targetConfig = await dbContext.WhatsAppConfigurations
                .FirstOrDefaultAsync(c => c.BranchId == target.BranchId);

            if (targetConfig == null)
            {
                targetConfig = new WhatsAppConfiguration
                {
                    BranchId = target.BranchId,
                    CompanyId = target.CompanyId,
                    CreatedBy = User.Identity?.Name,
                    CreatedDate = DateTime.Now
                };
                dbContext.WhatsAppConfigurations.Add(targetConfig);
            }

            targetConfig.ConfigName = $"{target.BranchName} WhatsApp Config";
            targetConfig.ApiUrl = hoConfig.ApiUrl;
            targetConfig.AuthHeaderKey = hoConfig.AuthHeaderKey;
            targetConfig.ApiKey = hoConfig.ApiKey;
            targetConfig.DefaultCountryCode = hoConfig.DefaultCountryCode;
            targetConfig.SenderPhone = hoConfig.SenderPhone;
            targetConfig.IsEnabled = hoConfig.IsEnabled;
            targetConfig.OpdNotificationEnabled = hoConfig.OpdNotificationEnabled;
            targetConfig.LabNotificationEnabled = hoConfig.LabNotificationEnabled;
            targetConfig.OpdMessageTemplate = hoConfig.OpdMessageTemplate;
            targetConfig.LabMessageTemplate = hoConfig.LabMessageTemplate;
            targetConfig.IsActive = true;
            targetConfig.ModifiedBy = User.Identity?.Name;
            targetConfig.ModifiedDate = DateTime.Now;

            copiedCount++;
        }

        await dbContext.SaveChangesAsync();

        var branchNamesStr = targetBranches.Count == 1 
            ? targetBranches[0].BranchName 
            : $"{copiedCount} target branches ({string.Join(", ", targetBranches.Select(b => b.BranchName))})";

        TempData["Success"] = $"Successfully copied Head Office WhatsApp configuration to {branchNamesStr}!";
        return RedirectToAction("Index");
    }

    private async Task<bool> CheckIsHOBranchAsync(int? branchId = null)
    {
        var sessionVal = HttpContext.Session.GetString("IsHOBranch");
        if (!string.IsNullOrEmpty(sessionVal) && bool.TryParse(sessionVal, out var isHOSession))
        {
            return isHOSession;
        }

        if (User.IsHOBranch())
        {
            return true;
        }

        var bId = branchId ?? User.GetCurrentBranchId();
        if (bId.HasValue)
        {
            var branch = await dbContext.BranchMasters.FindAsync(bId.Value);
            return branch?.IsHOBranch == true;
        }

        return false;
    }

    [HttpPost]
    public async Task<IActionResult> SendTestMessage([FromBody] WhatsAppTestRequest req)
    {
        if (req == null || string.IsNullOrWhiteSpace(req.ToPhone))
        {
            return Json(new { success = false, message = "Recipient phone number is required." });
        }

        var branchId = User.GetCurrentBranchId() ?? 1;
        var message = string.IsNullOrWhiteSpace(req.MessageText)
            ? "Hello from EMR System! This is a test WhatsApp message verifying your configuration."
            : req.MessageText.Trim();

        var result = await whatsAppService.SendTextMessageAsync(req.ToPhone.Trim(), message, branchId, "TEST");

        if (result.Success)
        {
            return Json(new
            {
                success = true,
                message = "Test message sent successfully!",
                msgId = result.MsgId,
                jid = result.Jid,
                status = result.Status
            });
        }
        else
        {
            return Json(new
            {
                success = false,
                message = result.ErrorMessage ?? "Failed to send test message.",
                raw = result.RawResponse
            });
        }
    }
}
