using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Utility > Accounts > Payees (page UTILITY.ACCOUNTS.PAYEES: VIEW, EDIT). Repeat vendors and staff, offered
/// on the petty expense and voucher screens (the name can still be typed freely there). A payee's default expense
/// head is filled in on a new petty expense.</summary>
public class AccPayeesController(IAccountsService accounts, IAuditLogService audit, ILogger<AccPayeesController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.PAYEES";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index(string? search = null) => View(new AccPayeesPageViewModel
    {
        Payees = await accounts.GetPayeesAsync(CompanyId, search: search),
        Heads = await accounts.GetExpenseHeadsAsync(CompanyId, activeOnly: true),
        Search = search
    });

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Save(AccPayeeDto form)
    {
        if (string.IsNullOrWhiteSpace(form.PayeeName)) return BackToList("Enter the payee name.", error: true);
        try
        {
            var id = await accounts.SavePayeeAsync(form, CompanyId, UserId);
            await audit.LogAsync(form.PayeeId == 0 ? "Create Payee" : "Update Payee", "Accounts.Payee", $"Payee #{id} '{form.PayeeName.Trim()}'{(form.IsActive ? "" : " (inactive)")}", UserId, OwnBranchId);
            return BackToList(form.PayeeId == 0 ? "Payee added." : "Payee updated.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Payee {PayeeId} could not be saved", form.PayeeId);
            return BackToList(Msg(ex), error: true);
        }
    }
}
