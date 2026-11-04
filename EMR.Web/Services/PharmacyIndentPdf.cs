using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>Purchase indent as an A4 PDF for the supplier (SQLScripts/2413).</summary>
public static class PharmacyIndentPdf
{
    static PharmacyIndentPdf() => QuestPDF.Settings.License = LicenseType.Community;

    public static byte[] Build(PhDoc d, PhBranchHeader h, PhSupplierInfo? s) =>
        Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4); page.Margin(28);
            page.DefaultTextStyle(t => t.FontSize(9.5f));
            page.Header().Column(c =>
            {
                c.Item().Row(r =>
                {
                    r.RelativeItem().Column(x =>
                    {
                        x.Item().Text(h.Name).FontSize(15).Bold().FontColor("#4c1d95");
                        if (!string.IsNullOrWhiteSpace(h.Address)) x.Item().Text(h.Address).FontSize(8.5f);
                        x.Item().Text(string.Join(" · ", new[] { h.Phone, h.Gstin != null ? "GSTIN " + h.Gstin : null, h.Licence20B != null ? "D.L. " + h.Licence20B + (h.Licence21B != null ? " / " + h.Licence21B : "") : null }
                            .Where(v => !string.IsNullOrWhiteSpace(v)))).FontSize(8.5f);
                    });
                    r.ConstantItem(170).AlignRight().Column(x =>
                    {
                        x.Item().AlignRight().Text("PURCHASE INDENT").FontSize(13).Bold();
                        x.Item().AlignRight().Text($"No. {d.DocNo}").Bold();
                        x.Item().AlignRight().Text($"Date {d.DocDate:dd-MMM-yyyy}");
                        if (d.Priority == "URGENT") x.Item().AlignRight().Text("URGENT").Bold().FontColor(Colors.Red.Darken2);
                    });
                });
                c.Item().PaddingVertical(6).LineHorizontal(1).LineColor("#c4b5fd");
                c.Item().Text(t => { t.Span("To: ").Bold(); t.Span(s?.SupplierName ?? d.SupplierName ?? ""); if (s?.Gstin != null) t.Span("   GSTIN " + s.Gstin); });
            });
            page.Content().PaddingTop(10).Column(c =>
            {
                c.Item().Text("Please supply the following items:").Italic();
                c.Item().PaddingTop(6).Table(t =>
                {
                    t.ColumnsDefinition(cd => { cd.ConstantColumn(26); cd.RelativeColumn(5); cd.RelativeColumn(2); cd.RelativeColumn(2); cd.RelativeColumn(3); });
                    static IContainer H(IContainer x) => x.Background("#f1ecff").Padding(4);
                    static IContainer B(IContainer x) => x.BorderBottom(0.5f).BorderColor("#e2e8f0").Padding(4);
                    t.Header(hd =>
                    {
                        hd.Cell().Element(H).Text("#").Bold(); hd.Cell().Element(H).Text("Item").Bold(); hd.Cell().Element(H).Text("Pack").Bold();
                        hd.Cell().Element(H).AlignRight().Text("Quantity").Bold(); hd.Cell().Element(H).Text("Remarks").Bold();
                    });
                    var i = 0;
                    foreach (var l in d.Lines)
                    {
                        t.Cell().Element(B).Text((++i).ToString());
                        t.Cell().Element(B).Text(((l.FormShort != null ? l.FormShort + " " : "") + l.ItemName).Trim());
                        t.Cell().Element(B).Text(l.PurchaseUom ?? "");
                        t.Cell().Element(B).AlignRight().Text($"{l.Qty:0.##} {l.PurchaseUom}");
                        t.Cell().Element(B).Text(l.Remarks ?? "");
                    }
                });
                if (!string.IsNullOrWhiteSpace(d.Remarks)) c.Item().PaddingTop(8).Text(t => { t.Span("Remarks: ").Bold(); t.Span(d.Remarks); });
                c.Item().PaddingTop(8).Text("Please send a quotation / confirm availability and expected delivery. Goods with adequate shelf life only.").FontSize(8.5f);
                c.Item().PaddingTop(24).Row(r =>
                {
                    r.RelativeItem().Text($"Raised by: {d.CreatedByName}");
                    r.RelativeItem().AlignRight().Text(d.ApprovedByName != null ? $"Approved by: {d.ApprovedByName}, {d.ApprovedDate:dd-MMM-yyyy}" : "");
                });
            });
            page.Footer().AlignCenter().Text(t => { t.Span("Page "); t.CurrentPageNumber(); t.Span(" of "); t.TotalPages(); t.Span($" · {h.Name}"); });
        })).GeneratePdf();
}
