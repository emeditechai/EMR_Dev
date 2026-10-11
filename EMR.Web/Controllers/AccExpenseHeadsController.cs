using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Utility > Accounts > Expense Heads (page UTILITY.ACCOUNTS.EXPENSEHEADS: VIEW, EDIT). What staff pick on a
/// petty expense; each head posts to one ledger (created with the head when none is chosen).</summary>
public class AccExpenseHeadsController(IAccountsService accounts, IAuditLogService audit, ILogger<AccExpenseHeadsController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.EXPENSEHEADS";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index()
    {
        var ledgers = await accounts.GetLedgersAsync(activeOnly: true);
        return View(new AccExpenseHeadsPageViewModel
        {
            Heads = await accounts.GetExpenseHeadsAsync(CompanyId),
            Ledgers = ledgers.Where(l => l.LedgerType is not ("CASH" or "BANK" or "PETTY") && l.GroupType is "Expense" or "Asset")
                             .Select(l => new AccOption { Id = l.LedgerId, Name = l.LedgerName, Extra = l.GroupName }).ToList()
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Save(AccExpenseHeadForm form)
    {
        if (string.IsNullOrWhiteSpace(form.HeadName)) return BackToList("Enter the expense head name.", error: true);
        try
        {
            var id = await accounts.SaveExpenseHeadAsync(form, CompanyId, UserId);
            await audit.LogAsync(form.ExpenseHeadId == 0 ? "Create Expense Head" : "Update Expense Head", "Accounts.ExpenseHead",
                $"Expense head #{id} '{form.HeadName.Trim()}'{(form.IsActive ? "" : " (inactive)")}", UserId, OwnBranchId);
            return BackToList(form.ExpenseHeadId == 0 ? "Expense head added." : "Expense head updated.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Expense head {HeadId} could not be saved", form.ExpenseHeadId);
            return BackToList(Msg(ex), error: true);
        }
    }
}
