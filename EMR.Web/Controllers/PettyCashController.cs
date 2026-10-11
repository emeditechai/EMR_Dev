using EMR.Shared.Security;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Petty Cash Counters and Petty Cash Closing (SQLScripts/2244).
/// UTILITY.ACCOUNTS.COUNTERS: VIEW, EDIT (add / edit a counter), FLOAT (issue / replenish / return - posts a Contra).
/// UTILITY.ACCOUNTS.CLOSING:  VIEW, CREATE (count the cash and close a day; a difference posts to shortage / excess).
/// </summary>
public class PettyCashController(IAccountsService accounts, IAuditLogService audit, ILogger<PettyCashController> logger) : AccountsControllerBase
{
    public const string CountersPage = "UTILITY.ACCOUNTS.COUNTERS";
    public const string ClosingPage = "UTILITY.ACCOUNTS.CLOSING";
    public const string FloatControl = "FLOAT";

    // ── Counters ──────────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(CountersPage, PermissionControls.View)]
    public async Task<IActionResult> Counters()
    {
        var branches = await accounts.GetBranchesAsync(CompanyId);
        var ledgers = await accounts.GetLedgersAsync(activeOnly: true);
        return View(new AccCountersPageViewModel
        {
            Counters = await accounts.GetCountersAsync(CompanyId, ScopeBranch()),
            Branches = SeesAllBranches ? branches : branches.Where(b => b.Id == OwnBranchId).ToList(),
            Users = await accounts.GetUsersAsync(CompanyId),
            FundingLedgers = ledgers.Where(l => l.LedgerType is "CASH" or "BANK").Select(l => new AccOption { Id = l.LedgerId, Name = l.LedgerName, Extra = l.LedgerType }).ToList(),
            CanPickBranch = SeesAllBranches,
            OwnBranchId = OwnBranchId
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(CountersPage, PermissionControls.Edit)]
    public async Task<IActionResult> SaveCounter(AccCounterForm form)
    {
        if (!CanUseBranch(form.BranchId)) return BackToList("You can keep counters only for your own branch.", error: true, action: nameof(Counters));
        if (form.CounterId > 0 && !await OwnsCounterAsync(form.CounterId)) return BackToList("Counter not found.", error: true, action: nameof(Counters));
        try
        {
            var id = await accounts.SaveCounterAsync(form, CompanyId, UserId);
            await audit.LogAsync(form.CounterId == 0 ? "Create Petty Cash Counter" : "Update Petty Cash Counter", "Accounts.PettyCounter",
                $"Counter #{id} '{form.CounterName?.Trim()}', float {form.FloatAmount:N2}{(form.IsActive ? "" : " (inactive)")}", UserId, form.BranchId);
            return BackToList(form.CounterId == 0 ? "Petty cash counter added. Issue its float to start using it." : "Petty cash counter updated.", action: nameof(Counters));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Petty cash counter {CounterId} could not be saved", form.CounterId);
            return BackToList(Msg(ex), error: true, action: nameof(Counters));
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(CountersPage, FloatControl)]
    public async Task<IActionResult> Float(AccFloatForm form)
    {
        if (!await OwnsCounterAsync(form.CounterId)) return BackToList("Counter not found.", error: true, action: nameof(Counters));
        try
        {
            var voucherNo = await accounts.SaveFloatAsync(form, UserId);
            var what = form.Kind switch { "ISSUE" => "Float issued", "REPLENISH" => "Counter replenished", _ => "Cash returned" };
            await audit.LogAsync("Petty Cash Float", "Accounts.PettyFloat", $"{what}: {form.Amount:N2} for counter #{form.CounterId}, voucher {voucherNo}", UserId, OwnBranchId);
            return BackToList($"{what}: ₹{form.Amount:N2}. Voucher {voucherNo}.", action: nameof(Counters));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Float {Kind} for counter {CounterId} failed", form.Kind, form.CounterId);
            return BackToList(Msg(ex), error: true, action: nameof(Counters));
        }
    }

    [HttpGet]
    [RequiresPermission(CountersPage, PermissionControls.View)]
    public async Task<IActionResult> FloatHistory(int counterId)
    {
        if (!await OwnsCounterAsync(counterId)) return Json(new { success = false, message = "Counter not found." });
        var rows = await accounts.GetFloatHistoryAsync(counterId);
        return Json(new
        {
            success = true,
            data = rows.Select(r => new
            {
                kind = r.Kind switch { "ISSUE" => "Float issue", "REPLENISH" => "Replenishment", _ => "Return" },
                date = r.TxnDate.ToString("dd-MMM-yyyy"), amount = r.Amount, source = r.SourceLedgerName, reference = r.ReferenceNo, remarks = r.Remarks,
                voucherNo = r.VoucherNo, by = r.CreatedByName
            })
        });
    }

    // ── Daily closing ─────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(ClosingPage, PermissionControls.View)]
    public async Task<IActionResult> Closing(int? counterId = null)
    {
        return View(new AccClosingPageViewModel
        {
            Counters = await accounts.GetCountersAsync(CompanyId, ScopeBranch(), activeOnly: true),
            Closings = await accounts.GetClosingsAsync(CompanyId, ScopeBranch(), counterId),
            CounterId = counterId
        });
    }

    /// <summary>Book balance of a counter at the end of a date - shown on the closing form before the cash is counted.</summary>
    [HttpGet]
    [RequiresPermission(ClosingPage, PermissionControls.View)]
    public async Task<IActionResult> ClosingBalance(int counterId, DateTime? date)
    {
        if (!await OwnsCounterAsync(counterId)) return Json(new { success = false, message = "Counter not found." });
        var balance = await accounts.GetCounterBookBalanceAsync(counterId, date ?? DateTime.Today);
        return Json(new { success = true, balance });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(ClosingPage, PermissionControls.Create)]
    public async Task<IActionResult> SaveClosing(AccClosingForm form)
    {
        if (!await OwnsCounterAsync(form.CounterId)) return BackToList("Select the petty cash counter.", error: true, action: nameof(Closing));
        try
        {
            var (book, diff) = await accounts.SaveClosingAsync(form, UserId);
            await audit.LogAsync("Petty Cash Closing", "Accounts.PettyClosing",
                $"Counter #{form.CounterId} closed for {form.ClosingDate:dd-MMM-yyyy}: book {book:N2}, counted {form.CountedCash:N2}, difference {diff:N2}", UserId, OwnBranchId);
            var note = diff == 0 ? "Cash tallies with the books." : diff < 0 ? $"Shortage of ₹{-diff:N2} posted." : $"Excess of ₹{diff:N2} posted.";
            return BackToList($"Counter closed for {form.ClosingDate:dd-MMM-yyyy}. {note}", action: nameof(Closing));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Closing of counter {CounterId} failed", form.CounterId);
            return BackToList(Msg(ex), error: true, action: nameof(Closing));
        }
    }

    private async Task<bool> OwnsCounterAsync(int counterId)
    {
        var counter = counterId > 0 ? await accounts.GetCounterAsync(CompanyId, counterId) : null;
        return counter is not null && CanUseBranch(counter.BranchId);
    }
}
