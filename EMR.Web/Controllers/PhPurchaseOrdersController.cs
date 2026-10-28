using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Purchase Order (PHARMACY.PURCHASEORDER): draft -> approve (PO number) -> received on GRNs; cancel / short-close.</summary>
public class PhPurchaseOrdersController(IPharmacyPurchaseService purchase, IAuditLogService audit, IEmailService email) : PharmacyPurchaseControllerBase(purchase, audit)
{
    protected override string Kind => "po";
    protected override string PageCode => "PHARMACY.PURCHASEORDER";
    protected override string Title => "Purchase Order";
    protected override string Icon => "bi-file-earmark-text";
    protected override string Description => "Order stock from a supplier at agreed rates. Approval gives the PO number; goods are received against it on a GRN.";

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0, int? indentId = null)
    {
        PhDoc? d;
        if (id > 0) d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
        else
        {
            d = new PhDoc { ExpectedDate = DateTime.Today.AddDays(3), Terms = "Goods with at least 12 months of shelf life. Rates inclusive of scheme as agreed.",
                            IsDirect = await Purchase.GrnNotRequiredAsync(BranchId), InvoiceDate = DateTime.Today };
            if (indentId != null)
            {
                d.RefId = indentId;
                d.RefNo = (await Purchase.GetAsync("indent", CompanyId, BranchId, indentId.Value))?.DocNo;
                d.Lines = await Purchase.IndentLinesForPoAsync(CompanyId, BranchId, indentId.Value);
                if (d.Lines.Count == 0) { TempData["Error"] = "The indent is not approved or is already ordered."; return RedirectToAction(nameof(Index)); }
            }
        }
        return d == null ? NotFound() : await FormView(d);
    }

    [HttpGet]
    public async Task<IActionResult> IndentLines(int indentId) => Json(await Purchase.IndentLinesForPoAsync(CompanyId, BranchId, indentId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = ReadDoc(json);
        if (d == null) return BadRequest();
        var (id, err) = await Purchase.SavePoAsync(CompanyId, BranchId, d, UserId);
        return await AfterSave(d, id, err, "Purchase order");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id)
    {
        var direct = (await Purchase.GetAsync(Kind, CompanyId, BranchId, id))?.IsDirect == true;
        return await Done(id, await Purchase.PoActionAsync(CompanyId, BranchId, id, "approve", UserId), "Approve", direct ? "Purchase approved and stock added (GRN not required)." : "Purchase order approved.");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id) => await Done(id, await Purchase.PoActionAsync(CompanyId, BranchId, id, "cancel", UserId), "Cancel", "Purchase order cancelled.");

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Close(int id) => await Done(id, await Purchase.PoActionAsync(CompanyId, BranchId, id, "close", UserId), "Close", "Purchase order short-closed.");

    [HttpGet]
    public async Task<IActionResult> RateHistory(int itemId) => Json(await Purchase.RateHistoryAsync(CompanyId, itemId));

    /// <summary>E-mails the approved order to the supplier's e-mail (Supplier master) through the branch's SMTP settings.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Email(int id)
    {
        var d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
        if (d == null) return NotFound();
        if (d.Status is not ("APPROVED" or "PARTIAL")) return await Done(id, "Only an approved order can be e-mailed.", "Email", "");
        var s = await Purchase.SupplierInfoAsync(CompanyId, BranchId, d.SupplierId!.Value);
        if (string.IsNullOrWhiteSpace(s?.Email)) return await Done(id, "The supplier has no e-mail address in the Supplier master.", "Email", "");
        var h = await Purchase.BranchHeaderAsync(BranchId);
        static string enc(string? v) => System.Net.WebUtility.HtmlEncode(v ?? "");
        var rows = string.Concat(d.Lines.Select((l, i) => $"<tr><td>{i + 1}</td><td>{enc(l.ItemName)}</td><td align='right'>{l.Qty:0.##} {enc(l.PurchaseUom)}</td><td align='right'>{l.FreeQty:0.##}</td><td align='right'>{l.Rate:0.00}</td><td align='right'>{l.DiscPercent:0.##}%</td><td align='right'>{l.GstPercent:0.##}%</td><td align='right'>{l.TaxableAmount + l.GstAmount:N2}</td></tr>"));
        var body = $@"<div style='font-family:Arial,sans-serif;font-size:13px'>
            <p>Dear {enc(s.SupplierName)},</p><p>Please supply the following against our <b>Purchase Order {enc(d.DocNo)}</b> dated {d.DocDate:dd-MMM-yyyy}{(d.ExpectedDate != null ? $", by <b>{d.ExpectedDate:dd-MMM-yyyy}</b>" : "")}.</p>
            <table border='1' cellpadding='5' cellspacing='0' style='border-collapse:collapse;font-size:12px'><tr style='background:#f1ecff'><th>#</th><th>Item</th><th>Qty</th><th>Free</th><th>Rate</th><th>Disc</th><th>GST</th><th>Amount</th></tr>{rows}
            <tr><td colspan='7' align='right'><b>Net amount</b></td><td align='right'><b>₹ {d.NetAmount:N2}</b></td></tr></table>
            <p>{enc(PharmacyPurchaseService.AmountInWords(d.NetAmount))}</p>
            {(string.IsNullOrWhiteSpace(d.Terms) ? "" : $"<p><b>Terms:</b> {enc(d.Terms)}</p>")}
            <p>Please quote the PO number on your invoice.</p><p>Regards,<br/>{enc(h.Name)}<br/>{enc(h.Address)}<br/>{enc(h.Phone)}{(h.Gstin != null ? "<br/>GSTIN " + enc(h.Gstin) : "")}{(h.Licence20B != null ? "<br/>D.L. " + enc(h.Licence20B) + (h.Licence21B != null ? " / " + enc(h.Licence21B) : "") : "")}</p></div>";
        var (ok, msg) = await email.SendEmailAsync(BranchId, s.Email!, $"Purchase Order {d.DocNo} - {h.Name}", body);
        if (!ok) return await Done(id, "E-mail not sent: " + msg, "Email", "");
        await Purchase.MarkEmailedAsync(id, s.Email!);
        return await Done(id, null, "Email", $"Purchase order e-mailed to {s.Email}.");
    }
}
