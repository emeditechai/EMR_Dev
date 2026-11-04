using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Purchase > Purchase Indent (PHARMACY.PURCHASEINDENT): draft -> submit -> approve / reject -> ordered by a PO.
/// SQLScripts/2413: the indent is raised on a supplier; approval follows the Approval Matrix (module PHARMACY.PURCHASEINDENT,
/// by branch) - with no matrix the indent is approved on submit; once approved, its PDF is e-mailed to the supplier when the
/// supplier has "Receive Indent E-mail" on (a failed e-mail never undoes the approval; "Send to supplier" re-sends).
/// </summary>
public class PhPurchaseIndentsController(IPharmacyPurchaseService purchase, IAuditLogService audit, IPharmacyInventoryService inventory,
    INotificationService notifications, IEmailService email, ILogger<PhPurchaseIndentsController> logger) : PharmacyPurchaseControllerBase(purchase, audit)
{
    private const string Module = "PHARMACY.PURCHASEINDENT";

    protected override string Kind => "indent";
    protected override string PageCode => "PHARMACY.PURCHASEINDENT";
    protected override string Title => "Purchase Indent";
    protected override string Icon => "bi-clipboard-plus";
    protected override string Description => "Ask for stock to be bought: items below reorder level are suggested. An approved indent becomes a purchase order.";

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var d = id > 0 ? await Purchase.GetAsync(Kind, CompanyId, BranchId, id) : new PhDoc { Priority = "NORMAL" };
        return d == null ? NotFound() : await FormView(d);
    }

    [HttpGet]
    public async Task<IActionResult> ReorderSuggest() => Json(await Purchase.ReorderSuggestAsync(CompanyId, BranchId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = ReadDoc(json);
        if (d == null) return BadRequest();
        var (id, err) = await Purchase.SaveIndentAsync(CompanyId, BranchId, d, UserId);
        return await AfterSave(d, id, err, "Indent");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Submit(int id)
    {
        var err = await Purchase.IndentActionAsync(CompanyId, BranchId, id, "submit", null, UserId);
        if (err != null) return await Done(id, err, "Submit", "");
        var approvers = await inventory.MatrixApproversAsync(CompanyId, Module, BranchId);
        if (approvers.Count == 0)
        {
            // no Approval Matrix for indents at this branch: approved on submit, then sent to the supplier
            var aerr = await Purchase.IndentActionAsync(CompanyId, BranchId, id, "approve", "Approved on submit (no approval matrix for indents).", UserId);
            if (aerr != null) return await Done(id, null, "Submit", "Indent submitted. It could not be approved automatically: " + aerr);
            return await Done(id, null, "Submit", "Indent submitted and approved (no approval matrix). " + await MailToSupplierAsync(id, auto: true));
        }
        var to = approvers.Where(u => u != UserId).ToList();
        if (to.Count > 0)
            await notifications.NotifyUsersAsync(to, "PHARMACY_APPROVAL", "INFO", "Purchase indent to approve", $"{User.Identity?.Name} submitted a purchase indent for approval.",
                Url.Action(nameof(Form), new { id })!, "PHARMACY", id, $"{Module}:{id}:{DateTime.Now:yyyyMMddHHmmss}", BranchId, UserId);
        return await Done(id, null, "Submit", "Indent submitted for approval (Approval Matrix).");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks)
    {
        var err = await MatrixCheckAsync() ?? await Purchase.IndentActionAsync(CompanyId, BranchId, id, "approve", remarks, UserId);
        if (err != null) return await Done(id, err, "Approve", "");
        return await Done(id, null, "Approve", "Indent approved. " + await MailToSupplierAsync(id, auto: true));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(int id, string? remarks) =>
        await Done(id, await MatrixCheckAsync() ?? await Purchase.IndentActionAsync(CompanyId, BranchId, id, "reject", remarks, UserId), "Reject", "Indent rejected.");

    /// <summary>"Send to supplier": e-mails the approved indent PDF again (any supplier with an e-mail, toggle or not).</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Email(int id)
    {
        var msg = await MailToSupplierAsync(id, auto: false);
        return await Done(id, msg.StartsWith("Indent e-mailed") ? null : msg, "Email", msg);
    }

    [HttpGet]
    public async Task<IActionResult> Pdf(int id)
    {
        var d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
        if (d == null) return NotFound();
        var s = d.SupplierId is int sid ? await Purchase.SupplierInfoAsync(CompanyId, BranchId, sid) : null;
        return File(PharmacyIndentPdf.Build(d, await Purchase.BranchHeaderAsync(BranchId), s), "application/pdf", $"Indent_{d.DocNo ?? id.ToString()}.pdf");
    }

    // Approval Matrix: the approvers named for this branch decide; none named -> the APPROVE control (already checked)
    private async Task<string?> MatrixCheckAsync()
    {
        var approvers = await inventory.MatrixApproversAsync(CompanyId, Module, BranchId);
        return approvers.Count == 0 || approvers.Contains(UserId) || User.IsSuperAdmin() ? null
            : "Only the approvers named in the Approval Matrix for Pharmacy Purchase Indent can approve or reject it.";
    }

    /// <summary>The indent PDF to the supplier's e-mail. auto = after approval: only when the supplier has "Receive Indent E-mail".
    /// Never throws; answers what happened (shown with the approval message).</summary>
    private async Task<string> MailToSupplierAsync(int id, bool auto)
    {
        try
        {
            var d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
            if (d == null) return "Indent not found.";
            if (d.Status is not ("APPROVED" or "ORDERED")) return "Only an approved indent can be sent to the supplier.";
            if (d.SupplierId is not int sid) return "The indent has no supplier.";
            var s = await Purchase.SupplierInfoAsync(CompanyId, BranchId, sid);
            if (auto && s?.ReceiveIndentEmail != true) return "";
            if (string.IsNullOrWhiteSpace(s?.Email)) return "Not e-mailed: the supplier has no e-mail in the Supplier master.";
            var h = await Purchase.BranchHeaderAsync(BranchId);
            var pdf = PharmacyIndentPdf.Build(d, h, s);
            static string enc(string? v) => System.Net.WebUtility.HtmlEncode(v ?? "");
            var body = $@"<div style='font-family:Arial,sans-serif;font-size:13px'><p>Dear {enc(s.SupplierName)},</p>
                <p>Please find attached our <b>Purchase Indent {enc(d.DocNo)}</b> dated {d.DocDate:dd-MMM-yyyy} ({d.Lines.Count} item(s)){(d.Priority == "URGENT" ? " - <b>URGENT</b>" : "")}.
                Kindly confirm availability, rates and the expected delivery.</p>
                <p>Regards,<br/>{enc(h.Name)}<br/>{enc(h.Address)}<br/>{enc(h.Phone)}</p></div>";
            using var att = new System.Net.Mail.Attachment(new MemoryStream(pdf), $"Indent_{d.DocNo}.pdf", "application/pdf");
            var (ok, msg) = await email.SendEmailAsync(BranchId, s.Email!, $"Purchase Indent {d.DocNo} - {h.Name}", body, [att]);
            if (!ok) return "E-mail to the supplier not sent: " + msg;
            await Purchase.MarkIndentEmailedAsync(id, s.Email!);
            await audit.LogAsync("PharmacyIndent", "Email", $"Purchase indent {d.DocNo} e-mailed to {s.Email}", UserId, BranchId);
            return $"Indent e-mailed to {s.Email}.";
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[PH-INDENT] e-mail of indent {Id} failed", id);
            return "E-mail to the supplier not sent (" + ex.Message + ").";
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string? remarks) => await Done(id, await Purchase.IndentActionAsync(CompanyId, BranchId, id, "cancel", remarks, UserId), "Cancel", "Indent cancelled.");
}
