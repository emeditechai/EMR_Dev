using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Utility > Accounts > Ledgers and Groups (page UTILITY.ACCOUNTS.LEDGERS: VIEW, EDIT). The chart of accounts.
/// Ledgers billing posts to are system ledgers: only their opening balance and remarks can change.</summary>
public class AccLedgersController(IAccountsService accounts, IAuditLogService audit, ILogger<AccLedgersController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.LEDGERS";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index(string? search = null, int? groupId = null, string? ledgerType = null)
    {
        return View(new AccLedgersPageViewModel
        {
            Ledgers = await accounts.GetLedgersAsync(search, groupId, ledgerType),
            Groups = await accounts.GetLedgerGroupsAsync(),
            Search = search, GroupId = groupId, LedgerType = ledgerType
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> SaveLedger(AccLedgerForm form)
    {
        if (!ModelState.IsValid) return BackToList(FirstError(), error: true);
        try
        {
            var id = await accounts.SaveLedgerAsync(form, UserId);
            await audit.LogAsync(form.LedgerId == 0 ? "Create Ledger" : "Update Ledger", "Accounts.Ledger",
                $"Ledger #{id} '{form.LedgerName.Trim()}' ({form.LedgerType}), opening {form.OpeningBalance:N2} {form.OpeningBalanceType}", UserId, OwnBranchId);
            return BackToList(form.LedgerId == 0 ? "Ledger added." : "Ledger updated.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Ledger {LedgerId} could not be saved", form.LedgerId);
            return BackToList(Msg(ex), error: true);
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> SaveGroup(AccLedgerGroupForm form)
    {
        if (!ModelState.IsValid) return BackToList(FirstError(), error: true);
        try
        {
            var id = await accounts.SaveLedgerGroupAsync(form, UserId);
            await audit.LogAsync(form.LedgerGroupId == 0 ? "Create Ledger Group" : "Update Ledger Group", "Accounts.LedgerGroup",
                $"Ledger group #{id} '{form.GroupName.Trim()}' ({form.GroupType})", UserId, OwnBranchId);
            return BackToList(form.LedgerGroupId == 0 ? "Ledger group added." : "Ledger group updated.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Ledger group {GroupId} could not be saved", form.LedgerGroupId);
            return BackToList(Msg(ex), error: true);
        }
    }

    private string FirstError() => ModelState.Values.SelectMany(v => v.Errors).Select(e => e.ErrorMessage).FirstOrDefault(m => !string.IsNullOrEmpty(m)) ?? "Check the values entered.";
}
