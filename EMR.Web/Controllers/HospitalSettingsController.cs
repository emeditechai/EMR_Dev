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
public class HospitalSettingsController(
    ApplicationDbContext dbContext,
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
        var settings = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (settings is null)
        {
            var empty = new HospitalSettingsViewModel
            {
                BranchId = branchId.Value,
                BranchName = branch?.BranchName ?? string.Empty
            };
            return View(empty);
        }

        var model = MapToViewModel(settings, branch?.BranchName ?? string.Empty);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Edit()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found.";
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var settings = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (settings is null)
        {
            return View(new HospitalSettingsViewModel
            {
                BranchId = branchId.Value,
                BranchName = branch?.BranchName ?? string.Empty,
                IsActive = true
            });
        }

        return View(MapToViewModel(settings, branch?.BranchName ?? string.Empty));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(HospitalSettingsViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return RedirectToAction("Index", "Dashboard");

        // Ensure the model is always tied to the session branch (no tampering)
        model.BranchId = branchId.Value;

        if (!ModelState.IsValid)
        {
            var br = await dbContext.BranchMasters.FindAsync(branchId.Value);
            model.BranchName = br?.BranchName ?? string.Empty;
            return View(model);
        }

        var userId = User.GetUserId();
        var existing = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (existing is null)
        {
            var entity = MapToEntity(model, userId);
            dbContext.HospitalSettings.Add(entity);
            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync("Create", "HospitalSettings",
                $"Hospital settings created for branch {branchId}", userId, branchId);
            TempData["Success"] = "Hospital settings saved successfully.";
        }
        else
        {
            existing.HospitalName = model.HospitalName;
            existing.Address = model.Address;
            existing.ContactNumber1 = model.ContactNumber1;
            existing.ContactNumber2 = model.ContactNumber2;
            existing.EmailAddress = model.EmailAddress;
            existing.Website = model.Website;
            existing.GSTCode = model.GSTCode;
            existing.LogoPath = model.LogoPath;
            existing.CheckInTime = TimeSpan.TryParse(model.CheckInTime, out var cin) ? cin : null;
            existing.CheckOutTime = TimeSpan.TryParse(model.CheckOutTime, out var cout) ? cout : null;
            existing.IsActive = model.IsActive;
            existing.ByPassActualDayRate = model.ByPassActualDayRate;
            existing.DiscountApprovalRequired = model.DiscountApprovalRequired;
            existing.MinimumBookingAmountRequired = model.MinimumBookingAmountRequired;
            existing.MinimumBookingAmount = model.MinimumBookingAmount;
            existing.NoShowGraceHours = model.NoShowGraceHours;
            existing.CancellationRefundApprovalThreshold = model.CancellationRefundApprovalThreshold;
            existing.LastModifiedDate = DateTime.UtcNow;
            existing.LastModifiedBy = userId;

            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync("Update", "HospitalSettings",
                $"Hospital settings updated for branch {branchId}", userId, branchId);
            TempData["Success"] = "Hospital settings updated successfully.";
        }

        return RedirectToAction(nameof(Index));
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static HospitalSettingsViewModel MapToViewModel(HospitalSettings s, string branchName) =>
        new()
        {
            Id = s.Id,
            BranchId = s.BranchId,
            BranchName = branchName,
            HospitalName = s.HospitalName,
            Address = s.Address,
            ContactNumber1 = s.ContactNumber1,
            ContactNumber2 = s.ContactNumber2,
            EmailAddress = s.EmailAddress,
            Website = s.Website,
            GSTCode = s.GSTCode,
            LogoPath = s.LogoPath,
            CheckInTime = s.CheckInTime.HasValue
                ? s.CheckInTime.Value.ToString(@"hh\:mm") : null,
            CheckOutTime = s.CheckOutTime.HasValue
                ? s.CheckOutTime.Value.ToString(@"hh\:mm") : null,
            IsActive = s.IsActive,
            ByPassActualDayRate = s.ByPassActualDayRate,
            DiscountApprovalRequired = s.DiscountApprovalRequired,
            MinimumBookingAmountRequired = s.MinimumBookingAmountRequired,
            MinimumBookingAmount = s.MinimumBookingAmount,
            NoShowGraceHours = s.NoShowGraceHours,
            CancellationRefundApprovalThreshold = s.CancellationRefundApprovalThreshold,
            CreatedDate = s.CreatedDate,
            LastModifiedDate = s.LastModifiedDate
        };

    private static HospitalSettings MapToEntity(HospitalSettingsViewModel m, int userId) =>
        new()
        {
            BranchId = m.BranchId,
            HospitalName = m.HospitalName,
            Address = m.Address,
            ContactNumber1 = m.ContactNumber1,
            ContactNumber2 = m.ContactNumber2,
            EmailAddress = m.EmailAddress,
            Website = m.Website,
            GSTCode = m.GSTCode,
            LogoPath = m.LogoPath,
            CheckInTime = TimeSpan.TryParse(m.CheckInTime, out var cin) ? cin : null,
            CheckOutTime = TimeSpan.TryParse(m.CheckOutTime, out var cout) ? cout : null,
            IsActive = m.IsActive,
            ByPassActualDayRate = m.ByPassActualDayRate,
            DiscountApprovalRequired = m.DiscountApprovalRequired,
            MinimumBookingAmountRequired = m.MinimumBookingAmountRequired,
            MinimumBookingAmount = m.MinimumBookingAmount,
            NoShowGraceHours = m.NoShowGraceHours,
            CancellationRefundApprovalThreshold = m.CancellationRefundApprovalThreshold,
            CreatedDate = DateTime.UtcNow,
            CreatedBy = userId
        };
}
