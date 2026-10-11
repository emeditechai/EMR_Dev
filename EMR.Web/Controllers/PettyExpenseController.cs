using ClosedXML.Excel;
using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Petty Expenses (SQLScripts/2244), page UTILITY.ACCOUNTS.PETTYEXPENSE:
/// VIEW, CREATE, EDIT (a waiting / rejected expense), APPROVE (approve or reject), CANCEL, PRINT, EXPORT, ATTACH (bill scans).
/// An expense reaches the ledger only when approved (at once when it is within the company's auto-approve limit):
/// Dr the ledger of each expense head, Cr the counter. Cancelling an approved expense posts the reversal.
/// </summary>
public class PettyExpenseController(IAccountsService accounts, IAuditLogService audit, ILogger<PettyExpenseController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.PETTYEXPENSE";
    public const string AttachControl = "ATTACH";
    private const string RefType = "PETTY_EXP";

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index(DateTime? fromDate, DateTime? toDate, int? counterId, string? status, string? search)
    {
        var (from, to) = Period(fromDate, toDate);
        return View(new AccPettyExpenseIndexViewModel
        {
            Expenses = await accounts.GetPettyExpensesAsync(CompanyId, ScopeBranch(), from, to, counterId, status, search),
            Counters = await accounts.GetCountersAsync(CompanyId, ScopeBranch()),
            FromDate = from, ToDate = to, CounterId = counterId, Status = status, Search = search
        });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Create)]
    public async Task<IActionResult> Create(int? counterId = null)
    {
        var form = await FillAsync(new AccPettyExpenseForm { Lines = [new AccPettyExpenseLineDto()] });
        form.CounterId = counterId is > 0 && form.Counters.Any(c => c.CounterId == counterId) ? counterId.Value
                       : form.Counters.Count == 1 ? form.Counters[0].CounterId : 0;
        if (form.Counters.Count == 0)
            TempData["ErrorMessage"] = "No active petty cash counter for your branch. Add one under Petty Cash Counters and issue its float.";
        return View("Form", form);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Create)]
    public Task<IActionResult> Create(AccPettyExpenseForm form, List<IFormFile>? files) => SaveAsync(form, files, isNew: true);

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Edit(int id)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        if (e.Status is not (AccStatus.Submitted or AccStatus.Rejected))
            return BackToList("Only an expense waiting for approval or a rejected one can be changed.", error: true, action: nameof(Details), route: new { id });

        return View("Form", await FillAsync(new AccPettyExpenseForm
        {
            ExpenseId = e.ExpenseId, CounterId = e.CounterId, ExpenseDate = e.ExpenseDate, PayeeName = e.PayeeName, BillNo = e.BillNo, BillDate = e.BillDate,
            Narration = e.Narration, Lines = e.Lines
        }));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Edit)]
    public async Task<IActionResult> Edit(int id, AccPettyExpenseForm form, List<IFormFile>? files)
    {
        if (id != form.ExpenseId || await LoadAsync(id) is null) return BackToList("Expense not found.", error: true);
        return await SaveAsync(form, files, isNew: false);
    }

    // ── Attachments ───────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Attachment(int id)
    {
        var a = await accounts.GetAttachmentAsync(CompanyId, id);
        if (a is null || a.RefType != RefType || await LoadAsync(a.RefId) is null) return NotFound();
        return ServeAttachment(a);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, AttachControl)]
    public async Task<IActionResult> AddAttachment(int id, List<IFormFile>? files)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        if (e.Status == AccStatus.Cancelled) return BackToList("A cancelled expense takes no more attachments.", error: true, action: nameof(Details), route: new { id });
        var (saved, error) = await SaveAttachmentsAsync(accounts, RefType, id, files);
        if (saved > 0) await audit.LogAsync("Petty Expense Attachment", "Accounts.PettyExpense", $"{saved} attachment(s) added to petty expense #{id} {e.DisplayNo}", UserId, e.BranchId);
        return BackToList(error ?? (saved > 0 ? $"{saved} attachment(s) added." : "Choose a file to attach."), error: error is not null || saved == 0, action: nameof(Details), route: new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, AttachControl)]
    public async Task<IActionResult> DeleteAttachment(int id, int attachmentId)
    {
        var e = await LoadAsync(id);
        var a = await accounts.GetAttachmentAsync(CompanyId, attachmentId);
        if (e is null || a is null || a.RefType != RefType || a.RefId != id) return BackToList("Attachment not found.", error: true);
        await accounts.DeleteAttachmentAsync(CompanyId, attachmentId, UserId);
        await audit.LogAsync("Petty Expense Attachment", "Accounts.PettyExpense", $"Attachment '{a.FileName}' removed from petty expense #{id} {e.DisplayNo}", UserId, e.BranchId);
        return BackToList("Attachment removed.", action: nameof(Details), route: new { id });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Details(int id)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        ViewBag.CurrentUserId = UserId;
        ViewBag.AllowSelfApproval = (await accounts.GetSettingsAsync(CompanyId)).AllowSelfApproval;
        return View(e);
    }

    /// <summary>Balance and limits of a counter for the entry form.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> CounterInfo(int counterId)
    {
        var c = await accounts.GetCounterAsync(CompanyId, counterId);
        if (c is null || !CanUseBranch(c.BranchId)) return Json(new { success = false, message = "Counter not found." });
        return Json(new
        {
            success = true, balance = c.Balance, pending = c.PendingAmount, available = c.Available, floatAmount = c.FloatAmount, branch = c.BranchName,
            lastClosing = c.LastClosingDate?.ToString("dd-MMM-yyyy")
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Approve)]
    public async Task<IActionResult> Approve(int id)
    {
        if (await LoadAsync(id) is null) return BackToList("Expense not found.", error: true);
        try
        {
            await accounts.ApprovePettyExpenseAsync(id, CompanyId, UserId);
            var e = await accounts.GetPettyExpenseAsync(CompanyId, id);
            await audit.LogAsync("Approve Petty Expense", "Accounts.PettyExpense", $"Petty expense #{id} approved and posted: {e?.VoucherNo}, {e?.TotalAmount:N2}", UserId, e?.BranchId);
            return BackToList($"Expense approved and posted. Voucher {e?.VoucherNo}.", action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Petty expense {ExpenseId} could not be approved", id);
            return BackToList(Msg(ex), error: true, action: nameof(Details), route: new { id });
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Approve)]
    public async Task<IActionResult> Reject(int id, string? reason)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        try
        {
            await accounts.RejectPettyExpenseAsync(id, CompanyId, reason, UserId);
            await audit.LogAsync("Reject Petty Expense", "Accounts.PettyExpense", $"Petty expense #{id} ({e.TotalAmount:N2}) rejected: {reason?.Trim()}", UserId, e.BranchId);
            return BackToList("Expense rejected. The person who entered it can correct and resubmit it.", action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Petty expense {ExpenseId} could not be rejected", id);
            return BackToList(Msg(ex), error: true, action: nameof(Details), route: new { id });
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Cancel)]
    public async Task<IActionResult> Cancel(int id, string? reason)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        try
        {
            await accounts.CancelPettyExpenseAsync(id, CompanyId, reason, UserId);
            await audit.LogAsync("Cancel Petty Expense", "Accounts.PettyExpense",
                $"Petty expense #{id} {e.DisplayNo} ({e.TotalAmount:N2}) cancelled{(e.Status == AccStatus.Approved ? " and reversed in the ledger" : "")}: {reason?.Trim()}", UserId, e.BranchId);
            return BackToList(e.Status == AccStatus.Approved ? "Expense cancelled. A reversal voucher has been posted and the cash is back in the counter." : "Expense cancelled.",
                action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Petty expense {ExpenseId} could not be cancelled", id);
            return BackToList(Msg(ex), error: true, action: nameof(Details), route: new { id });
        }
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Print)]
    public async Task<IActionResult> Print(int id)
    {
        var e = await LoadAsync(id);
        if (e is null) return BackToList("Expense not found.", error: true);
        return View("~/Views/AccVouchers/Print.cshtml", new AccVoucherPrintViewModel
        {
            Title = "Petty Cash Voucher", CompanyName = User.GetCompanyName(), BranchName = $"{e.BranchName} - {e.CounterName}", VoucherNo = e.DisplayNo,
            VoucherDate = e.ExpenseDate, PayeeName = e.PayeeName, PaymentMode = "Cash", InstrumentNo = e.BillNo is null ? null : $"Bill {e.BillNo}",
            Narration = e.Narration, StatusName = AccStatus.Name(e.Status), PreparedBy = e.CreatedByName,
            ApprovedBy = e.IsAutoApproved ? "Auto-approved (within limit)" : e.ApprovedByName, TotalAmount = e.TotalAmount,
            Lines = e.Lines.Select(l => new AccVoucherLineDto
            {
                LedgerName = l.HeadName, DebitAmount = l.Amount, Narration = l.GstAmount > 0 ? $"{l.Remarks} (incl. GST {l.GstAmount:N2})".Trim() : l.Remarks
            }).ToList()
        });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Export)]
    public async Task<IActionResult> Export(DateTime? fromDate, DateTime? toDate, int? counterId, string? status, string? search)
    {
        var (from, to) = Period(fromDate, toDate);
        var rows = await accounts.GetPettyExpensesAsync(CompanyId, ScopeBranch(), from, to, counterId, status, search);

        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("Petty Expenses");
        ws.Cell(1, 1).Value = $"Petty Expense Register  {from:dd-MMM-yyyy} to {to:dd-MMM-yyyy}";
        ws.Range(1, 1, 1, 12).Merge().Style.Font.SetBold().Font.SetFontSize(13);
        string[] heads = ["Date", "Voucher No", "Branch", "Counter", "Payee", "Expense Heads", "Bill No", "Narration", "Amount", "Status", "Entered By", "Approved By"];
        for (var i = 0; i < heads.Length; i++) ws.Cell(3, i + 1).Value = heads[i];
        ws.Range(3, 1, 3, heads.Length).Style.Font.SetBold().Fill.SetBackgroundColor(XLColor.FromHtml("#E2E8F0"));
        var r = 4;
        foreach (var e in rows)
        {
            ws.Cell(r, 1).Value = e.ExpenseDate; ws.Cell(r, 1).Style.DateFormat.Format = "dd-MMM-yyyy";
            ws.Cell(r, 2).Value = e.DisplayNo; ws.Cell(r, 3).Value = e.BranchName; ws.Cell(r, 4).Value = e.CounterName; ws.Cell(r, 5).Value = e.PayeeName;
            ws.Cell(r, 6).Value = e.Heads; ws.Cell(r, 7).Value = e.BillNo; ws.Cell(r, 8).Value = e.Narration;
            ws.Cell(r, 9).Value = e.TotalAmount; ws.Cell(r, 9).Style.NumberFormat.Format = "#,##0.00";
            ws.Cell(r, 10).Value = AccStatus.Name(e.Status); ws.Cell(r, 11).Value = e.CreatedByName;
            ws.Cell(r, 12).Value = e.IsAutoApproved ? "Auto" : e.ApprovedByName;
            r++;
        }
        ws.Cell(r, 8).Value = "Approved total"; ws.Cell(r, 9).Value = rows.Where(e => e.Status == AccStatus.Approved).Sum(e => e.TotalAmount);
        ws.Range(r, 8, r, 9).Style.Font.SetBold(); ws.Cell(r, 9).Style.NumberFormat.Format = "#,##0.00";
        ws.Columns().AdjustToContents(3, r);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"PettyExpenses_{from:yyyyMMdd}_{to:yyyyMMdd}.xlsx");
    }

    // ── helpers ───────────────────────────────────────────────────────────────
    private async Task<AccPettyExpenseDto?> LoadAsync(int id)
    {
        var e = id > 0 ? await accounts.GetPettyExpenseAsync(CompanyId, id) : null;
        return e is not null && CanUseBranch(e.BranchId) ? e : null;
    }

    private async Task<AccPettyExpenseForm> FillAsync(AccPettyExpenseForm form)
    {
        form.Counters = await accounts.GetCountersAsync(CompanyId, ScopeBranch(), activeOnly: true);
        form.Heads = await accounts.GetExpenseHeadsAsync(CompanyId, activeOnly: true);
        form.Payees = await accounts.GetPayeesAsync(CompanyId, activeOnly: true);
        form.Settings = await accounts.GetSettingsAsync(CompanyId);
        if (form.Lines.Count == 0) form.Lines.Add(new AccPettyExpenseLineDto());
        return form;
    }

    private async Task<IActionResult> SaveAsync(AccPettyExpenseForm form, List<IFormFile>? files, bool isNew)
    {
        // a blank amount box is not a binding error: empty lines are dropped and the rest is checked below
        foreach (var key in ModelState.Keys.Where(k => k.StartsWith("Lines[")).ToList()) ModelState.Remove(key);
        form.Lines = form.Lines.Where(l => l.ExpenseHeadId > 0 || l.Amount != 0).ToList();
        var counter = form.CounterId > 0 ? await accounts.GetCounterAsync(CompanyId, form.CounterId) : null;
        if (counter is null || !CanUseBranch(counter.BranchId)) ModelState.AddModelError(nameof(form.CounterId), "Select the petty cash counter.");
        if (form.Lines.Count == 0) ModelState.AddModelError(string.Empty, "Add at least one expense head with an amount.");
        if (form.Lines.Any(l => l.ExpenseHeadId <= 0)) ModelState.AddModelError(string.Empty, "Select the expense head on every line.");
        if (form.Lines.Any(l => l.Amount <= 0 || decimal.Round(l.Amount, 2) != l.Amount)) ModelState.AddModelError(string.Empty, "Every line needs an amount greater than zero, with at most two decimals.");
        if (form.Lines.Any(l => l.GstAmount < 0 || (l.GstAmount > 0 && l.GstAmount >= l.Amount))) ModelState.AddModelError(string.Empty, "GST on a line must be less than the amount paid (the amount includes the GST).");
        if (!ModelState.IsValid) return View("Form", await FillAsync(form));

        try
        {
            var (id, status, voucherNo) = await accounts.SavePettyExpenseAsync(form, CompanyId, UserId);
            var (_, fileError) = await SaveAttachmentsAsync(accounts, RefType, id, files);
            if (fileError is not null) TempData["ErrorMessage"] = "The expense is saved, but an attachment was not: " + fileError;
            var total = form.Lines.Sum(l => l.Amount);
            await audit.LogAsync(isNew ? "Create Petty Expense" : "Update Petty Expense", "Accounts.PettyExpense",
                $"Petty expense #{id} of {total:N2} from counter '{counter!.CounterName}'" + (status == AccStatus.Approved ? $" - auto-approved and posted, voucher {voucherNo}" : " - waiting for approval"),
                UserId, counter.BranchId);
            return BackToList(status == AccStatus.Approved ? $"Expense saved and posted. Voucher {voucherNo}." : "Expense saved. It is waiting for approval.",
                action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Petty expense {ExpenseId} could not be saved", form.ExpenseId);
            ModelState.AddModelError(string.Empty, Msg(ex));
            return View("Form", await FillAsync(form));
        }
    }
}
