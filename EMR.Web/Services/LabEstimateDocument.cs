using System.Globalization;
using System.Text.Json;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>A saved LAB B2C bill estimate (SQLScripts/2450) as the print page and the PDF show it.</summary>
public sealed class LabEstimateDoc
{
    public int EstimateId { get; init; }
    public string EstimateNo { get; init; } = "";
    public DateTime EstimateDate { get; init; }
    public DateTime ValidTill { get; init; }
    public bool IsExpired { get; init; }
    public string Status { get; init; } = "ACTIVE";
    public string? PatientCode { get; init; }
    public string PatientName { get; init; } = "";
    public string? Gender { get; init; }
    public int? AgeYears { get; init; }
    public string Mobile { get; init; } = "";
    public string? RefDoctorName { get; init; }
    public decimal GrossAmount { get; init; }
    public string? DiscountType { get; init; }
    public decimal DiscountValue { get; init; }
    public decimal DiscountAmount { get; init; }
    public string? MembershipCardNo { get; init; }
    public string? MembershipPlan { get; init; }
    public decimal MembershipDiscount { get; init; }
    public decimal GstAmount { get; init; }
    public decimal NetAmount { get; init; }
    public string? Remarks { get; init; }
    public Guid PublicToken { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = "";
    public string? BranchAddress { get; init; }
    public string? CreatedByName { get; init; }
    public int SentCount { get; init; }
    public DateTime? LastSentDate { get; init; }
    public string? LastSentTo { get; init; }
    public string? CancelReason { get; init; }
    public List<LabEstimateLine> Lines { get; init; } = new();
    public List<LabEstimateDept> DeptDiscounts { get; init; } = new();

    public string AgeGender => string.Join(" / ", new[] { AgeYears is int a ? a + " Yrs" : null, Gender }.Where(s => !string.IsNullOrWhiteSpace(s)));
    public string DiscountLabel => DiscountType switch
    {
        "P" => $"Discount ({DiscountValue:0.##}% on discountable items)",
        "F" => "Discount",
        "D" => "Department-wise discount",
        _ => "Discount"
    };
    public decimal? MaxTatHours => Lines.Where(l => l.ItemKind != "M").Max(l => l.TatHours);

    static string? S(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : v.ValueKind is JsonValueKind.Number ? v.ToString() : null;
    static decimal D(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0m;
    static decimal? Dn(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : null;
    static int I(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
    static int? In(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
    static bool B(JsonElement e, string n) => e.TryGetProperty(n, out var v) && (v.ValueKind == JsonValueKind.True || (v.ValueKind == JsonValueKind.Number && v.GetInt32() != 0));
    static DateTime T(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String && DateTime.TryParse(v.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : DateTime.MinValue;
    static DateTime? Tn(JsonElement e, string n) { var d = T(e, n); return d == DateTime.MinValue ? null : d; }

    /// <summary>From the API answer { header, lines, deptDiscounts }; null when the estimate does not exist.</summary>
    public static LabEstimateDoc? From(JsonElement data)
    {
        if (!data.TryGetProperty("header", out var h) || h.ValueKind != JsonValueKind.Object) return null;
        var address = string.Join(", ", new[] { S(h, "BranchAddress"), S(h, "BranchCity"), S(h, "BranchState"), S(h, "BranchPincode") }.Where(s => !string.IsNullOrWhiteSpace(s)));
        return new LabEstimateDoc
        {
            EstimateId = I(h, "EstimateId"), EstimateNo = S(h, "EstimateNo") ?? "", EstimateDate = T(h, "EstimateDate"), ValidTill = T(h, "ValidTill"),
            IsExpired = B(h, "IsExpired"), Status = S(h, "Status") ?? "ACTIVE", PatientCode = S(h, "PatientCode"),
            PatientName = ((S(h, "Salutation") is { Length: > 0 } sal ? sal + " " : "") + S(h, "PatientName")).Trim(),
            Gender = S(h, "Gender"), AgeYears = In(h, "AgeYears"), Mobile = S(h, "Mobile") ?? "", RefDoctorName = S(h, "RefDoctorName"),
            GrossAmount = D(h, "GrossAmount"), DiscountType = S(h, "DiscountType"), DiscountValue = D(h, "DiscountValue"), DiscountAmount = D(h, "DiscountAmount"),
            MembershipCardNo = S(h, "MembershipCardNo"), MembershipPlan = S(h, "MembershipPlan"), MembershipDiscount = D(h, "MembershipDiscount"),
            GstAmount = D(h, "GstAmount"), NetAmount = D(h, "NetAmount"), Remarks = S(h, "Remarks"),
            PublicToken = Guid.TryParse(S(h, "PublicToken"), out var g) ? g : Guid.Empty, BranchId = I(h, "BranchId"), BranchName = S(h, "BranchName") ?? "",
            BranchAddress = address.Length > 0 ? address : null, CreatedByName = S(h, "CreatedByName"), SentCount = I(h, "SentCount"),
            LastSentDate = Tn(h, "LastSentDate"), LastSentTo = S(h, "LastSentTo"), CancelReason = S(h, "CancelReason"),
            Lines = data.TryGetProperty("lines", out var ls) && ls.ValueKind == JsonValueKind.Array
                ? ls.EnumerateArray().Select(l => new LabEstimateLine(I(l, "LineSeq"), S(l, "ItemKind") ?? "T", S(l, "ItemCode"), S(l, "ItemName") ?? "", S(l, "GroupName"),
                    S(l, "SampleType"), Dn(l, "TatHours"), I(l, "Qty"), D(l, "Rate"), D(l, "Amount"), D(l, "DiscountAmount") + D(l, "MemberDiscount"), S(l, "MemberRule"), D(l, "GstPercent"), D(l, "GstAmount"), D(l, "LineTotal"))).ToList()
                : new(),
            DeptDiscounts = data.TryGetProperty("deptDiscounts", out var ds) && ds.ValueKind == JsonValueKind.Array
                ? ds.EnumerateArray().Select(x => new LabEstimateDept(S(x, "GroupName") ?? "", S(x, "DiscType") ?? "P", D(x, "DiscValue"), D(x, "DiscAmount"))).ToList()
                : new()
        };
    }
}

public sealed record LabEstimateLine(int LineSeq, string ItemKind, string? ItemCode, string ItemName, string? GroupName, string? SampleType, decimal? TatHours,
    int Qty, decimal Rate, decimal Amount, decimal DiscountAmount, string? MemberRule, decimal GstPercent, decimal GstAmount, decimal LineTotal)
{
    public string KindLabel => ItemKind switch { "R" => "Profile", "P" => "Package", "M" => "Charge", _ => "Test" };
}

public sealed record LabEstimateDept(string GroupName, string DiscType, decimal DiscValue, decimal DiscAmount);

/// <summary>The estimate as an A4 PDF (sent to the patient's WhatsApp, downloaded from the screen).</summary>
public static class LabEstimatePdf
{
    static LabEstimatePdf() => QuestPDF.Settings.License = LicenseType.Community;
    static string R(decimal v) => "Rs " + v.ToString("N2", CultureInfo.GetCultureInfo("en-IN"));

    public static byte[] Build(LabEstimateDoc d) =>
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
                        x.Item().Text(d.BranchName).FontSize(15).Bold().FontColor("#0f766e");
                        if (!string.IsNullOrWhiteSpace(d.BranchAddress)) x.Item().Text(d.BranchAddress).FontSize(8.5f);
                    });
                    r.ConstantItem(190).AlignRight().Column(x =>
                    {
                        x.Item().AlignRight().Text("LAB BILL ESTIMATE").FontSize(13).Bold();
                        x.Item().AlignRight().Text($"No. {d.EstimateNo}").Bold();
                        x.Item().AlignRight().Text($"Date {d.EstimateDate:dd-MMM-yyyy hh:mm tt}");
                        x.Item().AlignRight().Text($"Valid till {d.ValidTill:dd-MMM-yyyy}").FontColor(d.IsExpired ? Colors.Red.Darken2 : "#334155");
                        if (d.Status == "CANCELLED") x.Item().AlignRight().Text("CANCELLED").Bold().FontColor(Colors.Red.Darken2);
                    });
                });
                c.Item().PaddingVertical(6).LineHorizontal(1).LineColor("#99f6e4");
                c.Item().Row(r =>
                {
                    r.RelativeItem().Text(t => { t.Span("Patient: ").Bold(); t.Span(d.PatientName); if (d.AgeGender.Length > 0) t.Span("  (" + d.AgeGender + ")"); if (d.PatientCode != null) t.Span("  · " + d.PatientCode); });
                    r.ConstantItem(170).AlignRight().Text(t => { t.Span("Mobile: ").Bold(); t.Span(d.Mobile); });
                });
                if (!string.IsNullOrWhiteSpace(d.RefDoctorName)) c.Item().Text(t => { t.Span("Referred by: ").Bold(); t.Span(d.RefDoctorName); });
            });
            page.Content().PaddingTop(10).Column(c =>
            {
                c.Item().Table(t =>
                {
                    t.ColumnsDefinition(cd => { cd.ConstantColumn(22); cd.RelativeColumn(6); cd.RelativeColumn(2); cd.ConstantColumn(30); cd.RelativeColumn(2); cd.RelativeColumn(2); cd.RelativeColumn(2); });
                    static IContainer H(IContainer x) => x.Background("#ccfbf1").Padding(4);
                    static IContainer B(IContainer x) => x.BorderBottom(0.5f).BorderColor("#e2e8f0").Padding(4);
                    t.Header(hd =>
                    {
                        hd.Cell().Element(H).Text("#").Bold(); hd.Cell().Element(H).Text("Test / profile / package / charge").Bold(); hd.Cell().Element(H).Text("Type").Bold();
                        hd.Cell().Element(H).AlignRight().Text("Qty").Bold(); hd.Cell().Element(H).AlignRight().Text("Amount").Bold();
                        hd.Cell().Element(H).AlignRight().Text("Discount").Bold(); hd.Cell().Element(H).AlignRight().Text("Net").Bold();
                    });
                    foreach (var l in d.Lines)
                    {
                        t.Cell().Element(B).Text(l.LineSeq.ToString());
                        t.Cell().Element(B).Column(x =>
                        {
                            x.Item().Text(l.ItemName).SemiBold();
                            var sub = string.Join(" · ", new[] { l.ItemCode, l.GroupName, l.SampleType, l.GstPercent > 0 ? $"GST {l.GstPercent:0.##}% {R(l.GstAmount)}" : null, l.MemberRule != null ? "Membership: " + l.MemberRule : null }.Where(s => !string.IsNullOrWhiteSpace(s)));
                            if (sub.Length > 0) x.Item().Text(sub).FontSize(7.5f).FontColor("#64748b");
                        });
                        t.Cell().Element(B).Text(l.KindLabel);
                        t.Cell().Element(B).AlignRight().Text(l.Qty.ToString());
                        t.Cell().Element(B).AlignRight().Text(R(l.Amount));
                        t.Cell().Element(B).AlignRight().Text(l.DiscountAmount > 0 ? "-" + R(l.DiscountAmount) : "—");
                        t.Cell().Element(B).AlignRight().Text(R(l.LineTotal));
                    }
                });
                c.Item().PaddingTop(8).AlignRight().Width(260).Column(x =>
                {
                    void Row(string k, string v, bool bold = false) => x.Item().Row(r => { r.RelativeItem().Text(k).Bold(); r.ConstantItem(110).AlignRight().Text(v).Bold(); });
                    x.Item().Row(r => { r.RelativeItem().Text("Total amount"); r.ConstantItem(110).AlignRight().Text(R(d.GrossAmount)); });
                    if (d.MembershipDiscount > 0) x.Item().Row(r => { r.RelativeItem().Text($"Membership benefit ({d.MembershipCardNo} · {d.MembershipPlan})"); r.ConstantItem(110).AlignRight().Text("-" + R(d.MembershipDiscount)).FontColor(Colors.Red.Darken2); });
                    if (d.DiscountAmount > 0) x.Item().Row(r => { r.RelativeItem().Text(d.DiscountLabel); r.ConstantItem(110).AlignRight().Text("-" + R(d.DiscountAmount)).FontColor(Colors.Red.Darken2); });
                    foreach (var dd in d.DeptDiscounts)
                        x.Item().Row(r => { r.RelativeItem().PaddingLeft(10).Text($"{dd.GroupName} ({(dd.DiscType == "P" ? dd.DiscValue.ToString("0.##") + "%" : R(dd.DiscValue))})").FontSize(8); r.ConstantItem(110).AlignRight().Text("-" + R(dd.DiscAmount)).FontSize(8); });
                    if (d.GstAmount > 0) x.Item().Row(r => { r.RelativeItem().Text("GST (misc charges)"); r.ConstantItem(110).AlignRight().Text(R(d.GstAmount)); });
                    x.Item().PaddingTop(3).BorderTop(1).BorderColor("#0f766e").PaddingTop(3).Row(r => { r.RelativeItem().Text("Estimated amount").Bold().FontSize(11); r.ConstantItem(110).AlignRight().Text(R(d.NetAmount)).Bold().FontSize(11); });
                });
                if (d.MaxTatHours is decimal tat && tat > 0)
                    c.Item().PaddingTop(8).Text($"Reports are usually ready within {tat:0.#} hour(s) of sample collection.").FontSize(8.5f);
                if (!string.IsNullOrWhiteSpace(d.Remarks)) c.Item().PaddingTop(4).Text(t => { t.Span("Remarks: ").Bold(); t.Span(d.Remarks); });
                c.Item().PaddingTop(12).Background("#f8fafc").Padding(8).Text(
                    $"This is an estimate, not a bill. Rates are as on {d.EstimateDate:dd-MMM-yyyy} and valid till {d.ValidTill:dd-MMM-yyyy}; the final bill may differ if tests, rates or offers change. No payment has been taken.")
                    .FontSize(8).Italic().FontColor("#475569");
            });
            page.Footer().Row(r =>
            {
                r.RelativeItem().Text($"Prepared by {d.CreatedByName ?? "—"}").FontSize(7.5f).FontColor("#64748b");
                r.RelativeItem().AlignRight().Text(t => { t.Span("Page ").FontSize(7.5f); t.CurrentPageNumber().FontSize(7.5f); t.Span(" of ").FontSize(7.5f); t.TotalPages().FontSize(7.5f); });
            });
        })).GeneratePdf();
}
