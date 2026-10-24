using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Opening Balances (SQLScripts/2322; page UTILITY.ACCOUNTS.OPENING: VIEW, EDIT).
/// The balances of the asset and liability ledgers on the go-live date, per branch, posted as one Opening Balance voucher
/// (OPN) so every report includes them. Saving again cancels the previous opening entry and posts the new one. Debits and
/// credits should agree; a difference is posted to "Opening Balance Difference" and shown until it is corrected.
/// </summary>
public class AccOpeningController(IAccountsService accounts, IAuditLogService audit, ILogger<AccOpeningController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.OPENING";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index(int? branchId)
    {
        var branches = await accounts.GetBranchesAsync(CompanyId);
        var id = SeesAllBranches ? (branchId is > 0 ? branchId.Value : OwnBranchId ?? branches.FirstOrDefault()?.Id ?? 0) : OwnBranchId ?? 0;
        if (id <= 0) return RedirectToAction("SelectBranch", "Account");
        var (header, lines) = await accounts.GetOpeningAsync(CompanyId, id);
        var settings = await accounts.GetSettingsAsync(CompanyId);
        var today = DateTime.Today;
        var fyStartMonth = settings.FinancialYearStartMonth is >= 1 and <= 12 ? settings.FinancialYearStartMonth : 4;
        var fyStart = new DateTime(today.Month >= fyStartMonth ? today.Year : today.Year - 1, fyStartMonth, 1);
        return View(new AccOpeningPageViewModel
        {
            BranchId = id,
            BranchName = branches.FirstOrDefault(b => b.Id == id)?.Name,
            CanPickBranch = SeesAllBranches,
            Branches = SeesAllBranches ? branches : [],
            Header = header,
            Lines = lines,
            AsOfDate = header?.AsOfDate.Date ?? fyStart
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Save(AccOpeningForm form)
    {
        if (form.BranchId <= 0 || !CanUseBranch(form.BranchId))
        {
            TempData["ErrorMessage"] = "You can enter the opening balances only of your own branch.";
            return RedirectToAction(nameof(Index));
        }
        if (form.Lines.Any(l => l.Debit < 0 || l.Credit < 0))
        {
            TempData["ErrorMessage"] = "Opening amounts cannot be negative - enter them on the other side.";
            return RedirectToAction(nameof(Index), new { branchId = form.BranchId });
        }
        try
        {
            var (voucherNo, difference) = await accounts.SaveOpeningAsync(CompanyId, form, UserId);
            await audit.LogAsync("Save Opening Balances", "Accounts.Opening",
                $"Opening balances of branch #{form.BranchId} as of {form.AsOfDate:dd-MMM-yyyy}: {voucherNo ?? "cleared"}" +
                (difference != 0 ? $", difference {difference:N2} posted to Opening Balance Difference" : ""), UserId, form.BranchId);
            TempData[difference == 0 ? "SuccessMessage" : "ErrorMessage"] = voucherNo is null
                ? "Opening balances cleared."
                : difference == 0
                    ? $"Opening balances saved ({voucherNo}). Debits and credits agree."
                    : $"Opening balances saved ({voucherNo}), but debits and credits differ by ₹{Math.Abs(difference):N2} - it is held in \"Opening Balance Difference\" until corrected.";
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Opening balances of branch {BranchId} could not be saved", form.BranchId);
            TempData["ErrorMessage"] = Msg(ex);
        }
        return RedirectToAction(nameof(Index), new { branchId = form.BranchId });
    }
}
