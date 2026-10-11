using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Accounts Settings (page UTILITY.ACCOUNTS.SETTINGS: VIEW, EDIT, LOCK).
/// The settings are one row per company, applied to every branch: petty cash limits and approval, GST input credit,
/// back-dating, financial year. The books are locked branch by branch (LOCK): no entry dated on or before the lock.
/// </summary>
public class AccSettingsController(IAccountsService accounts, IAuditLogService audit, ILogger<AccSettingsController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.SETTINGS";
    public const string LockControl = "LOCK";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index() => View(await PageAsync(await accounts.GetSettingsAsync(CompanyId)));

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Save([Bind(Prefix = "Settings")] AccSettingsDto form)
    {
        form.CompanyId = CompanyId;
        if (!ModelState.IsValid) return View(nameof(Index), await PageAsync(form));
        try
        {
            await accounts.SaveSettingsAsync(form, UserId);
            await audit.LogAsync("Update Accounts Settings", "Accounts.Settings",
                $"Petty approval {(form.PettyApprovalRequired ? "on" : "off")}, auto-approve up to {form.PettyAutoApproveLimit:N2}, max per voucher {form.PettyMaxPerVoucher:N2}, " +
                $"GST input credit {(form.PettyGstInputCredit ? "on" : "off")}, voucher approval {(form.VoucherApprovalRequired ? "on" : "off")}, back-date {form.BackDateDays} day(s)",
                UserId, OwnBranchId);
            return BackToList("Accounts settings saved.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Accounts settings could not be saved");
            ModelState.AddModelError(string.Empty, Msg(ex));
            return View(nameof(Index), await PageAsync(form));
        }
    }

    /// <summary>Locks the books of one branch up to a past date, or unlocks them (no date).</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, LockControl)]
    public async Task<IActionResult> SaveLock(int branchId, DateTime? lockedUpTo)
    {
        if (branchId <= 0 || !CanUseBranch(branchId)) return BackToList("You can lock the books only of your own branch.", error: true);
        try
        {
            await accounts.SaveBranchLockAsync(CompanyId, branchId, lockedUpTo, UserId);
            await audit.LogAsync(lockedUpTo.HasValue ? "Lock Branch Books" : "Unlock Branch Books", "Accounts.BranchLock",
                lockedUpTo.HasValue ? $"Books of branch #{branchId} locked up to {lockedUpTo:dd-MMM-yyyy}" : $"Books of branch #{branchId} unlocked", UserId, branchId);
            return BackToList(lockedUpTo.HasValue ? $"Books locked up to {lockedUpTo:dd-MMM-yyyy}." : "Books unlocked.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Books of branch {BranchId} could not be locked", branchId);
            return BackToList(Msg(ex), error: true);
        }
    }

    private async Task<AccSettingsPageViewModel> PageAsync(AccSettingsDto settings) => new()
    {
        Settings = settings,
        Locks = await accounts.GetBranchLocksAsync(CompanyId, ScopeBranch())
    };
}
