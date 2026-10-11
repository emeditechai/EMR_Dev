using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Accounts > Voucher Entry (SQLScripts/2244), page UTILITY.ACCOUNTS.VOUCHERS:
/// VIEW, CREATE, APPROVE (approve or reject), CANCEL, PRINT, ATTACH (bill scans). Manual Payment / Receipt / Contra / Journal vouchers for
/// what the system does not post on its own. A voucher must balance; it posts on save, or on approval when the
/// company asks for voucher approval. A posted voucher is never edited: it is cancelled (reversed) and re-entered.
/// </summary>
public class AccVouchersController(IAccountsService accounts, IAuditLogService audit, ILogger<AccVouchersController> logger) : AccountsControllerBase
{
    public const string PageCode = "UTILITY.ACCOUNTS.VOUCHERS";
    public const string AttachControl = "ATTACH";
    private const string RefType = "VOUCHER";

    public static readonly (string Code, string Name, string Hint)[] Types =
    [
        ("PMT", "Payment", "Money paid from cash or bank: credit the cash / bank ledger, debit the expense or party."),
        ("RCT", "Receipt", "Money received outside billing: debit the cash / bank ledger, credit the income or party."),
        ("CTR", "Contra", "Cash to bank or bank to cash: only cash and bank ledgers."),
        ("JRN", "Journal", "Adjustments and corrections: no cash or bank ledger.")
    ];

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index(DateTime? fromDate, DateTime? toDate, string? typeCode, string? status, int? branchId, string? search)
    {
        var (from, to) = Period(fromDate, toDate);
        return View(new AccVoucherIndexViewModel
        {
            Vouchers = await accounts.GetVouchersAsync(CompanyId, ScopeBranch(branchId), from, to, typeCode, status, search),
            Branches = await accounts.GetBranchesAsync(CompanyId),
            FromDate = from, ToDate = to, TypeCode = typeCode, Status = status, BranchId = branchId, Search = search, CanPickBranch = SeesAllBranches
        });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Create)]
    public async Task<IActionResult> Create(string? type = null)
    {
        var form = new AccVoucherForm
        {
            VoucherTypeCode = Types.Any(t => t.Code == type) ? type! : "PMT",
            BranchId = OwnBranchId ?? 0,
            Lines = [new AccVoucherLineDto(), new AccVoucherLineDto()]
        };
        return View(await FillAsync(form));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Create)]
    public async Task<IActionResult> Create(AccVoucherForm form, List<IFormFile>? files)
    {
        if (!SeesAllBranches) form.BranchId = OwnBranchId ?? 0;
        // a blank amount box is not a binding error: empty lines are dropped and the rest is checked below
        foreach (var key in ModelState.Keys.Where(k => k.StartsWith("Lines[")).ToList()) ModelState.Remove(key);
        form.Lines = form.Lines.Where(l => l.LedgerId > 0 || l.DebitAmount != 0 || l.CreditAmount != 0).ToList();

        if (!Types.Any(t => t.Code == form.VoucherTypeCode)) ModelState.AddModelError(nameof(form.VoucherTypeCode), "Select the voucher type.");
        if (form.BranchId <= 0) ModelState.AddModelError(nameof(form.BranchId), "Select the branch.");
        if (form.Lines.Count < 2) ModelState.AddModelError(string.Empty, "A voucher needs at least one debit and one credit line.");
        if (form.Lines.Any(l => l.LedgerId <= 0)) ModelState.AddModelError(string.Empty, "Select the ledger on every line.");
        if (form.Lines.Any(l => l.DebitAmount < 0 || l.CreditAmount < 0 || (l.DebitAmount > 0) == (l.CreditAmount > 0)))
            ModelState.AddModelError(string.Empty, "Every line needs either a debit or a credit amount.");
        var dr = form.Lines.Sum(l => l.DebitAmount);
        var cr = form.Lines.Sum(l => l.CreditAmount);
        if (dr != cr) ModelState.AddModelError(string.Empty, $"The voucher does not balance: debit {dr:N2}, credit {cr:N2}.");
        if (!ModelState.IsValid) return View(await FillAsync(form));

        try
        {
            var (id, status, voucherNo) = await accounts.SaveVoucherAsync(form, CompanyId, UserId);
            var (_, fileError) = await SaveAttachmentsAsync(accounts, RefType, id, files);
            if (fileError is not null) TempData["ErrorMessage"] = "The voucher is saved, but an attachment was not: " + fileError;
            var typeName = Types.First(t => t.Code == form.VoucherTypeCode).Name;
            await audit.LogAsync("Create Voucher", "Accounts.Voucher",
                $"{typeName} voucher #{id} of {dr:N2}" + (status == AccStatus.Approved ? $" posted: {voucherNo}" : " - waiting for approval"), UserId, form.BranchId);
            return BackToList(status == AccStatus.Approved ? $"{typeName} voucher posted: {voucherNo}." : $"{typeName} voucher saved. It is waiting for approval.",
                action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Voucher could not be saved");
            ModelState.AddModelError(string.Empty, Msg(ex));
            return View(await FillAsync(form));
        }
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Details(int id)
    {
        var v = await LoadAsync(id);
        if (v is null) return BackToList("Voucher not found.", error: true);
        ViewBag.CurrentUserId = UserId;
        ViewBag.AllowSelfApproval = (await accounts.GetSettingsAsync(CompanyId)).AllowSelfApproval;
        return View(v);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Approve)]
    public Task<IActionResult> Approve(int id) => ActAsync(id, "APPROVE", null, "Voucher approved and posted.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Approve)]
    public Task<IActionResult> Reject(int id, string? reason) => ActAsync(id, "REJECT", reason, "Voucher rejected.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, PermissionControls.Cancel)]
    public Task<IActionResult> Cancel(int id, string? reason) => ActAsync(id, "CANCEL", reason, "Voucher cancelled. If it was posted, its reversal has been posted.");

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
        var v = await LoadAsync(id);
        if (v is null) return BackToList("Voucher not found.", error: true);
        if (v.Status is AccStatus.Cancelled or AccStatus.Rejected) return BackToList("A cancelled or rejected voucher takes no more attachments.", error: true, action: nameof(Details), route: new { id });
        var (saved, error) = await SaveAttachmentsAsync(accounts, RefType, id, files);
        if (saved > 0) await audit.LogAsync("Voucher Attachment", "Accounts.Voucher", $"{saved} attachment(s) added to voucher #{id} {v.DisplayNo}", UserId, v.BranchId);
        return BackToList(error ?? (saved > 0 ? $"{saved} attachment(s) added." : "Choose a file to attach."), error: error is not null || saved == 0, action: nameof(Details), route: new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, AttachControl)]
    public async Task<IActionResult> DeleteAttachment(int id, int attachmentId)
    {
        var v = await LoadAsync(id);
        var a = await accounts.GetAttachmentAsync(CompanyId, attachmentId);
        if (v is null || a is null || a.RefType != RefType || a.RefId != id) return BackToList("Attachment not found.", error: true);
        await accounts.DeleteAttachmentAsync(CompanyId, attachmentId, UserId);
        await audit.LogAsync("Voucher Attachment", "Accounts.Voucher", $"Attachment '{a.FileName}' removed from voucher #{id} {v.DisplayNo}", UserId, v.BranchId);
        return BackToList("Attachment removed.", action: nameof(Details), route: new { id });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Print)]
    public async Task<IActionResult> Print(int id)
    {
        var v = await LoadAsync(id);
        if (v is null) return BackToList("Voucher not found.", error: true);
        return View(new AccVoucherPrintViewModel
        {
            Title = $"{v.VoucherTypeName} Voucher", CompanyName = User.GetCompanyName(), BranchName = v.BranchName, VoucherNo = v.DisplayNo, VoucherDate = v.VoucherDate,
            PayeeName = v.PayeeName, PaymentMode = v.PaymentMode, InstrumentNo = v.InstrumentNo, Narration = v.Narration, StatusName = AccStatus.Name(v.Status),
            PreparedBy = v.CreatedByName, ApprovedBy = v.ApprovedByName, TotalAmount = v.TotalAmount, Lines = v.Lines
        });
    }

    // ── helpers ───────────────────────────────────────────────────────────────
    private async Task<AccVoucherDto?> LoadAsync(int id)
    {
        var v = id > 0 ? await accounts.GetVoucherAsync(CompanyId, id) : null;
        return v is not null && CanUseBranch(v.BranchId) ? v : null;
    }

    private async Task<AccVoucherForm> FillAsync(AccVoucherForm form)
    {
        var branches = await accounts.GetBranchesAsync(CompanyId);
        form.Branches = SeesAllBranches ? branches : branches.Where(b => b.Id == OwnBranchId).ToList();
        form.Ledgers = (await accounts.GetLedgersAsync(activeOnly: true)).Where(l => l.LedgerType != "PETTY").ToList();
        form.PaymentModes = await accounts.GetPaymentModesAsync(CompanyId);
        form.Payees = await accounts.GetPayeesAsync(CompanyId, activeOnly: true);
        form.CanPickBranch = SeesAllBranches;
        form.Settings = await accounts.GetSettingsAsync(CompanyId);
        while (form.Lines.Count < 2) form.Lines.Add(new AccVoucherLineDto());
        return form;
    }

    private async Task<IActionResult> ActAsync(int id, string action, string? reason, string done)
    {
        var v = await LoadAsync(id);
        if (v is null) return BackToList("Voucher not found.", error: true);
        try
        {
            await accounts.VoucherActionAsync(id, CompanyId, action, reason, UserId);
            await audit.LogAsync($"Voucher {action}", "Accounts.Voucher",
                $"{v.VoucherTypeName} voucher #{id} {v.DisplayNo} ({v.TotalAmount:N2}): {action}{(string.IsNullOrWhiteSpace(reason) ? "" : " - " + reason.Trim())}", UserId, v.BranchId);
            return BackToList(done, action: nameof(Details), route: new { id });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Voucher {VoucherId} action {Action} failed", id, action);
            return BackToList(Msg(ex), error: true, action: nameof(Details), route: new { id });
        }
    }
}
