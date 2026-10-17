using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Cashier Day Closing (SQLScripts/2275), shared by OPD > OPD Day Closing (OpdDayClosingController) and
/// LAB > LAB Day Closing (LabDayClosingController): the user's own cash of the module at the current branch, petty cash
/// common to both (a float goes into the first closing that takes it). The derived controllers carry the page
/// permissions; the verify procedure requires the Manager or Finance role and the VERIFY control (role or user permission, per branch), whatever
/// the authorization mode, and refuses a user's own closing unless Hospital Settings allows it.
/// </summary>
public abstract class DayClosingControllerBase(IDayClosingService closings, INotificationService notifications, IAuditLogService audit, ILogger logger)
    : AccountsControllerBase
{
    protected abstract string Module { get; }
    private string ModuleTitle => Module == "OPD" ? "OPD" : "LAB";

    private IActionResult NoBranch() => Json(new { success = false, message = "Select a branch first." });

    protected IActionResult IndexView()
    {
        ViewData["Module"] = Module;
        return View("~/Views/DayClosing/Index.cshtml");
    }

    protected IActionResult VerifyView()
    {
        ViewData["Module"] = Module;
        return View("~/Views/DayClosing/Verify.cshtml");
    }

    protected async Task<IActionResult> SummaryCore(DateTime? date, int? id, bool includePetty)
    {
        if (OwnBranchId is not int branchId) return NoBranch();
        try
        {
            var day = (date ?? DateTime.Today).Date;
            if (day > DateTime.Today) day = DateTime.Today;
            var s = await closings.GetSummaryAsync(Module, branchId, UserId, day, id, includePetty);
            var pending = (await closings.GetPendingAsync(UserId, branchId, Module)).Where(p => p.BusinessDate < DateTime.Today).ToList();
            var history = await closings.GetMyListAsync(Module, branchId, UserId);
            return Json(new { success = true, header = s.Header, lines = s.Lines, transactions = s.Transactions, closings = s.Closings, pending, history });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "{Module} day closing summary failed for user {UserId}", Module, UserId);
            return Json(new { success = false, message = Msg(ex) });
        }
    }

    protected async Task<IActionResult> ReceiversCore()
    {
        if (OwnBranchId is not int branchId) return NoBranch();
        return Json(new { success = true, users = await closings.GetReceiversAsync(branchId, UserId, Module) });
    }

    protected async Task<IActionResult> SubmitCore(DayClosingSubmitForm form)
    {
        if (OwnBranchId is not int branchId) return NoBranch();
        try
        {
            var r = await closings.SubmitAsync(Module, form, branchId, UserId);
            var diff = r.Difference == 0 ? "tallied" : (r.Difference < 0 ? "short ₹" : "excess ₹") + Math.Abs(r.Difference).ToString("N2");
            await audit.LogAsync("Day Closing", $"{ModuleTitle}.DayClosingSubmit",
                $"{ModuleTitle} day closing {r.ClosingNo} of {form.BusinessDate:dd-MMM-yyyy} submitted: expected ₹{r.ExpectedCash:N2}, counted ₹{r.CountedCash:N2}, {diff}; " +
                $"handed over ₹{form.HandedAmount:N2} ({form.HandoverMode}), float kept ₹{form.RetainedFloat:N2}", UserId, branchId);

            // the verifiers of the branch (and the person who received the cash) hear about it
            var to = (await closings.GetVerifiersAsync(branchId, Module)).Select(v => v.UserId).Where(id => id != UserId).ToList();
            if (form.HandoverMode == "PERSON" && form.HandedToUserId is int h && h != UserId && !to.Contains(h)) to.Add(h);
            var who = User.GetDisplayName();
            await notifications.NotifyUsersAsync(to, "DAY_CLOSING", r.Difference == 0 ? "INFO" : "WARNING",
                $"{ModuleTitle} day closing to verify · {who}",
                $"{who} closed the {ModuleTitle} cash of {form.BusinessDate:dd-MMM-yyyy}: expected ₹{r.ExpectedCash:N2}, counted ₹{r.CountedCash:N2} ({diff}). " +
                $"Handed over ₹{form.HandedAmount:N2}" + (form.HandoverMode == "BANK" ? " by bank deposit" : "") + $", float kept ₹{form.RetainedFloat:N2}.",
                Url.Action("Verify", new { date = form.BusinessDate.ToString("yyyy-MM-dd") }), "CASH", r.CashClosingId,
                $"DAY_CLOSING_SUBMIT:{r.CashClosingId}:{DateTime.Now:yyyyMMddHHmmss}", branchId, UserId);

            await closings.ClearPendingNoticesIfDoneAsync(UserId);   // the last open day closed: its old reminders go
            return Json(new { success = true, r.CashClosingId, r.ClosingNo, r.Difference, message = $"{ModuleTitle} day closing {r.ClosingNo} submitted for verification." });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "{Module} day closing submit failed for user {UserId}", Module, UserId);
            return Json(new { success = false, message = Msg(ex) });
        }
    }

    /// <summary>The hand-over slip: the cashier's own closing (own = true) or, for a verifier, any closing of the branch.</summary>
    protected async Task<IActionResult> SlipCore(int id, bool own)
    {
        var (c, lines) = await closings.GetAsync(id);
        if (c == null || c.Module != Module || (own ? c.UserId != UserId : c.BranchId != OwnBranchId)) return NotFound();
        return View("~/Views/DayClosing/Slip.cshtml", (c, lines));
    }

    protected async Task<IActionResult> BoardCore(DateTime? date)
    {
        if (OwnBranchId is not int branchId) return NoBranch();
        try
        {
            var (list, open) = await closings.GetBoardAsync(Module, branchId, (date ?? DateTime.Today).Date);
            var canVerify = await closings.CanVerifyAsync(UserId, branchId, Module);
            var allowSelf = await closings.AllowsSelfVerifyAsync(branchId);
            return Json(new { success = true, closings = list, open, canVerify, allowSelf, me = UserId });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "{Module} day closing board failed", Module);
            return Json(new { success = false, message = Msg(ex) });
        }
    }

    protected async Task<IActionResult> DetailCore(int id)
    {
        var (c, lines) = await closings.GetAsync(id);
        if (c == null || c.Module != Module || c.BranchId != OwnBranchId) return Json(new { success = false, message = "Day closing not found." });
        return Json(new { success = true, closing = c, lines });
    }

    protected async Task<IActionResult> VerifyActionCore(int id, string action, string? remarks)
    {
        var (c, _) = await closings.GetAsync(id);
        if (c == null || c.Module != Module || c.BranchId != OwnBranchId) return Json(new { success = false, message = "Day closing not found." });
        try
        {
            var act = action == "B" ? "B" : "V";
            var r = await closings.VerifyAsync(id, act, remarks, UserId);
            var what = act == "V" ? "verified" : "sent back";
            await audit.LogAsync("Day Closing", act == "V" ? $"{ModuleTitle}.DayClosingVerify" : $"{ModuleTitle}.DayClosingSendBack",
                $"{ModuleTitle} day closing {r.ClosingNo} {what}" + (r.VoucherNo != null ? $"; difference posted in {r.VoucherNo}" : "") +
                (string.IsNullOrWhiteSpace(remarks) ? "" : $" - {remarks}"), UserId, c.BranchId);

            var who = User.GetDisplayName();
            await notifications.NotifyUsersAsync([r.CashierId], "DAY_CLOSING", act == "V" ? "INFO" : "WARNING",
                act == "V" ? $"{ModuleTitle} day closing verified · {c.BusinessDate:dd-MMM-yyyy}" : $"{ModuleTitle} day closing sent back · {c.BusinessDate:dd-MMM-yyyy}",
                act == "V"
                    ? $"{who} verified your {ModuleTitle} cash closing {r.ClosingNo}." +
                      (c.Difference < 0 ? $" The shortage of ₹{Math.Abs(c.Difference):N2} is recoverable from you." : c.Difference > 0 ? $" The excess of ₹{c.Difference:N2} is taken to income." : "")
                    : $"{who} sent back your {ModuleTitle} cash closing {r.ClosingNo}: {remarks}. Correct it and submit again.",
                Url.Action("Index", new { date = c.BusinessDate.ToString("yyyy-MM-dd") }), "CASH", id,
                $"DAY_CLOSING_{act}:{id}:{DateTime.Now:yyyyMMddHHmmss}", c.BranchId, UserId);

            return Json(new { success = true, message = $"{ModuleTitle} day closing {r.ClosingNo} {what}." + (r.VoucherNo != null ? $" Difference posted: {r.VoucherNo}." : "") });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "{Module} day closing {Id} verify failed", Module, id);
            return Json(new { success = false, message = Msg(ex) });
        }
    }
}
