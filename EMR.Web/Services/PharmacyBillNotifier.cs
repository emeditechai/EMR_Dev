using System.Net;
using System.Net.Mail;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>
/// Pharmacy > Sales (SQLScripts/2348): the sale bill as a PDF (tax invoice) and its WhatsApp / e-mail to the buyer -
/// on demand from Sale Bills (control SEND) and after every bill when Hospital Settings > MED > "Send Pharmacy Bill by
/// WhatsApp / E-mail" is Yes. Same channels as the OPD certificate notifications.
/// </summary>
public interface IPharmacyBillNotifier
{
    byte[] Pdf(PhSaleBill bill, PhBranchHeader header);
    Task<List<string>> SendAsync(int companyId, int branchId, int saleId);
}

public class PharmacyBillNotifier(IPharmacySaleService sales, IPharmacyPurchaseService purchase, IWhatsAppService whatsApp, IEmailService email,
    ILogger<PharmacyBillNotifier> logger) : IPharmacyBillNotifier
{
    static PharmacyBillNotifier() => QuestPDF.Settings.License = LicenseType.Community;

    public byte[] Pdf(PhSaleBill b, PhBranchHeader h)
    {
        const string Brand = "#644098";
        static string N(decimal v) => v.ToString("N2");
        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A5.Landscape()); page.Margin(18); page.DefaultTextStyle(t => t.FontSize(8.5f));
            page.Header().Column(c =>
            {
                c.Item().Row(r =>
                {
                    r.RelativeItem().Column(x =>
                    {
                        x.Item().Text(h.Name).FontSize(13).Bold().FontColor(Brand);
                        if (!string.IsNullOrWhiteSpace(h.Address)) x.Item().Text(h.Address);
                        x.Item().Text($"{(h.Phone != null ? "Ph " + h.Phone : "")}{(h.Gstin != null ? "   GSTIN " + h.Gstin : "")}");
                        if (h.Licence20B != null || h.Licence21B != null) x.Item().Text($"D.L. No. {h.Licence20B}{(h.Licence21B != null ? " / " + h.Licence21B : "")}");
                    });
                    r.ConstantItem(170).AlignRight().Column(x =>
                    {
                        x.Item().AlignRight().Text(b.Status == "CANCELLED" ? "TAX INVOICE (CANCELLED)" : "TAX INVOICE").Bold().FontSize(11);
                        x.Item().AlignRight().Text($"Bill {b.SaleNo}").Bold();
                        x.Item().AlignRight().Text(b.SaleDate.ToString("dd-MMM-yyyy HH:mm"));
                    });
                });
                c.Item().PaddingVertical(4).LineHorizontal(1).LineColor(Brand);
                c.Item().Row(r =>
                {
                    r.RelativeItem().Text(t => { t.Span("Patient / customer: ").SemiBold(); t.Span($"{b.CustomerName ?? "Walk-in"}{(b.PatientCode != null ? " (UHID " + b.PatientCode + ")" : "")}{(b.Mobile != null ? " · " + b.Mobile : "")}"); });
                    if (!string.IsNullOrWhiteSpace(b.DoctorName)) r.RelativeItem().AlignRight().Text(t => { t.Span("Doctor: ").SemiBold(); t.Span($"{b.DoctorName}{(b.RxNo != null ? " · Rx " + b.RxNo : "")}"); });
                });
            });
            page.Content().PaddingTop(6).Column(c =>
            {
                c.Item().Table(t =>
                {
                    t.ColumnsDefinition(cd => { cd.ConstantColumn(16); cd.RelativeColumn(4); cd.RelativeColumn(1.3f); cd.RelativeColumn(1.2f); cd.RelativeColumn(1); cd.RelativeColumn(1); cd.RelativeColumn(1.1f); cd.RelativeColumn(0.9f); cd.RelativeColumn(0.9f); cd.RelativeColumn(1.3f); });
                    t.Header(hd =>
                    {
                        foreach (var x in new[] { "#", "Item", "HSN", "Batch", "Exp.", "Qty", "MRP", "Disc%", "GST%", "Amount" })
                            hd.Cell().Background("#f1ecff").Padding(2).Text(x).SemiBold();
                    });
                    var i = 0;
                    foreach (var l in b.Lines)
                    {
                        t.Cell().Padding(2).Text((++i).ToString());
                        t.Cell().Padding(2).Text($"{l.FormShort} {l.ItemName}{(l.ScheduleCode is "H" or "H1" or "X" or "NDPS" ? " [" + l.ScheduleCode + "]" : "")}");
                        t.Cell().Padding(2).Text(l.HsnCode ?? "");
                        t.Cell().Padding(2).Text(l.BatchNo);
                        t.Cell().Padding(2).Text(l.ExpiryDate.ToString("MM/yy"));
                        t.Cell().Padding(2).AlignRight().Text($"{l.Qty:0.##} {l.SaleUom}");
                        t.Cell().Padding(2).AlignRight().Text(N(l.UnitMrp * l.Qty));
                        t.Cell().Padding(2).AlignRight().Text(l.DiscPercent.ToString("0.##"));
                        t.Cell().Padding(2).AlignRight().Text(l.GstPercent.ToString("0.##"));
                        t.Cell().Padding(2).AlignRight().Text(N(l.Amount));
                    }
                });
                c.Item().PaddingTop(6).Row(r =>
                {
                    r.RelativeItem().Column(x =>
                    {
                        x.Item().Text($"Amount in words: {PharmacyPurchaseService.AmountInWords(b.NetAmount)}").Italic();
                        if (b.MrpAmount > b.NetAmount) x.Item().Text($"You saved ₹{N(b.MrpAmount - b.NetAmount)} on MRP.").FontColor("#15803d").SemiBold();
                        x.Item().PaddingTop(4).Text(string.Join("   ", b.Payments.Select(p => $"{p.MethodName} ₹{N(p.Amount)}"))).FontColor("#4b5563");
                        if (b.BalanceDue > 0) x.Item().Text($"Balance due (credit): ₹{N(b.BalanceDue)}").Bold().FontColor("#b91c1c");
                    });
                    r.ConstantItem(200).Table(t =>
                    {
                        t.ColumnsDefinition(cd => { cd.RelativeColumn(); cd.ConstantColumn(80); });
                        void Row(string k, string v, bool bold = false) { t.Cell().Text(k); var c2 = t.Cell().AlignRight().Text(v); if (bold) c2.Bold(); }
                        Row("MRP value", N(b.MrpAmount)); Row("Less discount", N(b.DiscountAmount)); Row("Taxable value", N(b.TaxableAmount));
                        Row("CGST", N(b.CgstAmount)); Row("SGST", N(b.SgstAmount)); Row("Round off", N(b.RoundOff)); Row("Net amount ₹", N(b.NetAmount), true);
                    });
                });
            });
            page.Footer().Row(r =>
            {
                r.RelativeItem().Text("Medicines once sold are taken back only as per the pharmacy's return policy. Keep medicines out of reach of children.").FontSize(7).FontColor("#6b7280");
                r.ConstantItem(170).AlignRight().Text($"Pharmacist: {h.Pharmacist}").FontSize(7.5f);
            });
        })).GeneratePdf();
    }

    public async Task<List<string>> SendAsync(int companyId, int branchId, int saleId)
    {
        var outcome = new List<string>();
        var b = await sales.GetAsync(companyId, branchId, saleId);
        if (b == null) { outcome.Add("Bill not found."); return outcome; }
        var h = await purchase.BranchHeaderAsync(branchId);
        byte[] pdf;
        try { pdf = Pdf(b, h); }
        catch (Exception ex) { logger.LogError(ex, "[PH-BILL] PDF failed for sale {Id}", saleId); outcome.Add("The bill PDF could not be made."); return outcome; }
        var file = $"Bill_{(b.SaleNo ?? saleId.ToString()).Replace('/', '-')}.pdf";
        var message = $"Dear {b.CustomerName ?? "Customer"}, thank you for your purchase at {h.Name}. Your bill {b.SaleNo} of ₹{b.NetAmount:N2} dated {b.SaleDate:dd MMM yyyy} is attached.";

        // WhatsApp
        try
        {
            if (string.IsNullOrWhiteSpace(b.Mobile)) outcome.Add("WhatsApp: no mobile number on the bill.");
            else if (await whatsApp.GetActiveConfigAsync(branchId) is not { IsEnabled: true }) outcome.Add("WhatsApp: not configured for this branch.");
            else
            {
                var url = await whatsApp.UploadMediaAsync(pdf, "application/pdf", branchId);
                if (string.IsNullOrWhiteSpace(url)) outcome.Add("WhatsApp: the PDF could not be uploaded.");
                else
                {
                    var r = await whatsApp.SendTextMessageAsync(b.Mobile!, message, branchId, "PHR", saleId, url, file);
                    outcome.Add(r.Success ? $"WhatsApp: sent to {b.Mobile}." : "WhatsApp: " + (r.ErrorMessage ?? "not accepted."));
                }
            }
        }
        catch (Exception ex) { logger.LogError(ex, "[PH-BILL] WhatsApp failed for sale {Id}", saleId); outcome.Add("WhatsApp: send failed."); }

        // e-mail
        try
        {
            if (string.IsNullOrWhiteSpace(b.Email)) outcome.Add("E-mail: no e-mail address on the bill.");
            else
            {
                var body = EmailLayout.Wrap(EmailLayout.P(WebUtility.HtmlEncode(message))
                    + EmailLayout.Details(("Bill No", WebUtility.HtmlEncode(b.SaleNo ?? "")), ("Date", b.SaleDate.ToString("dd MMM yyyy")), ("Amount", "₹" + b.NetAmount.ToString("N2"))),
                    heading: "Pharmacy bill", organisation: h.Name);
                using var stream = new MemoryStream(pdf);
                using var att = new Attachment(stream, file, "application/pdf");
                var (ok, text) = await email.SendEmailAsync(branchId, b.Email!, $"Your pharmacy bill {b.SaleNo} - {h.Name}", body, [att]);
                outcome.Add(ok ? $"E-mail: sent to {b.Email}." : "E-mail: " + text);
            }
        }
        catch (Exception ex) { logger.LogError(ex, "[PH-BILL] e-mail failed for sale {Id}", saleId); outcome.Add("E-mail: send failed."); }
        return outcome;
    }
}
