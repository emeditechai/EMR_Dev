using QRCoder;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>Images the certificate PDF needs, read from wwwroot (png / jpg); any of them may be missing.</summary>
public class CertificatePdfImages
{
    public byte[]? Logo { get; set; }
    public byte[]? Photo { get; set; }
    public byte[]? Signature { get; set; }
    public byte[]? Stamp { get; set; }
}

/// <summary>
/// The issued certificate as an A4 PDF (QuestPDF): the same letterhead, wording by type, signature block, QR code and
/// legal note as Views/Certificates/Print.cshtml. Sent to the patient by WhatsApp / e-mail (SQLScripts/2342).
/// Keep the wording here in step with the print view.
/// </summary>
public static class CertificatePdfDocument
{
    private const string Navy = "#0f3d5e";
    private const string Grey = "#4b5563";
    private const string Line = "#9ca3af";

    static CertificatePdfDocument()
    {
        // QuestPDF Community licence (free for organisations under the licence's revenue threshold).
        QuestPDF.Settings.License = LicenseType.Community;
    }

    /// <summary>Renders the certificate. If an image is unreadable it is rendered again without images.</summary>
    public static byte[] Generate(CertificatePrintModel m, CertificatePdfImages images)
    {
        try
        {
            return Build(m, images).GeneratePdf();
        }
        catch (Exception)
        {
            return Build(m, new CertificatePdfImages()).GeneratePdf();
        }
    }

    private static string Dt(DateTime? x) => x?.ToString("dd/MM/yyyy") ?? "________";
    private static string Blank(string? v, int w = 18) => string.IsNullOrWhiteSpace(v) ? new string('_', w) : v;

    private static byte[] Qr(string url)
    {
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(url, QRCodeGenerator.ECCLevel.M);
        return new PngByteQRCode(data).GetGraphic(8);
    }

    private static Document Build(CertificatePrintModel m, CertificatePdfImages img)
    {
        var c = m.Certificate; var p = m.Patient; var d = m.Doctor;
        var issue = c.IssueDate ?? DateTime.Today;
        string Bd(string key) { var v = m.B(key); return DateTime.TryParse(v, out var x) ? x.ToString("dd/MM/yyyy") : v; }
        var name = $"{p.Salutation} {p.FullName}".Trim();
        var relation = string.IsNullOrWhiteSpace(p.GuardianName) ? "" : $", {(p.Gender == "Female" ? "D/o or W/o" : "S/o")} {p.GuardianName}";
        var age = Blank(p.AgeText(issue), 6);
        var gender = p.Gender?.ToLower() ?? "";
        var days = c.ValidFrom is { } f && c.ValidTo is { } t && t >= f ? (t - f).Days + 1 : 0;
        var regNo = string.IsNullOrWhiteSpace(d?.RegistrationNo) ? d?.MedicalLicenseNo : d!.RegistrationNo;
        var docName = Blank(d?.DoctorName?.Replace("Dr. ", "").Replace("Dr ", ""), 20);
        var verdict = m.B("verdict") switch
        {
            "FIT" => "MEDICALLY FIT", "FIT_RESTRICTED" => "MEDICALLY FIT WITH RESTRICTIONS",
            "TEMP_UNFIT" => "TEMPORARILY UNFIT", "UNFIT" => "MEDICALLY UNFIT", _ => "________"
        };
        var watermark = c.Status == "C" ? "CANCELLED" : c.Status == "D" ? "DRAFT" : null;
        var qr = string.IsNullOrWhiteSpace(m.VerifyUrl) ? null : Qr(m.VerifyUrl);

        return Document.Create(doc => doc.Page(page =>
        {
            page.Size(PageSizes.A4);
            page.Margin(14, Unit.Millimetre);
            page.DefaultTextStyle(x => x.FontSize(11).LineHeight(1.45f));

            if (watermark != null)
                page.Foreground().AlignCenter().AlignMiddle().Rotate(-30)
                    .Text(watermark).FontSize(80).Bold().FontColor("#dc262622");

            page.Header().Column(h =>
            {
                h.Item().BorderBottom(2).BorderColor(Navy).PaddingBottom(6).Row(r =>
                {
                    if (img.Logo != null) r.ConstantItem(32, Unit.Millimetre).MaxHeight(20, Unit.Millimetre).Image(img.Logo).FitArea();
                    r.RelativeItem().PaddingLeft(8).Column(x =>
                    {
                        x.Item().Text(m.HospitalName ?? "").FontSize(18).Bold().FontColor(Navy);
                        if (!string.IsNullOrWhiteSpace(m.HospitalAddress)) x.Item().Text(m.HospitalAddress).FontSize(9).FontColor(Grey);
                        var contact = string.Join("  ·  ", new[]
                        {
                            string.IsNullOrWhiteSpace(m.HospitalPhone) ? null : "Ph: " + m.HospitalPhone, m.HospitalEmail,
                            string.IsNullOrWhiteSpace(m.HospitalRegNo) ? null : "Regn. No.: " + m.HospitalRegNo
                        }.Where(v => !string.IsNullOrWhiteSpace(v)));
                        if (contact.Length > 0) x.Item().Text(contact).FontSize(9).FontColor(Grey);
                    });
                });
                h.Item().PaddingTop(5).DefaultTextStyle(x => x.FontSize(9)).Row(r =>
                {
                    r.RelativeItem().Text(t => { t.Span("Certificate No.: "); t.Span(c.CertificateNo ?? "—").Bold(); });
                    r.RelativeItem().AlignCenter().Text(t =>
                    {
                        t.Span("Patient ID: "); t.Span(p.PatientCode).Bold();
                        if (m.Visit?.OPDBillNo is { } bill) t.Span("  ·  OPD Ref.: " + bill);
                    });
                    r.RelativeItem().AlignRight().Text(t => { t.Span("Date: "); t.Span(Dt(issue)).Bold(); });
                });
            });

            page.Content().PaddingTop(12).Column(col =>
            {
                col.Spacing(7);
                col.Item().PaddingBottom(4).AlignCenter().Text(m.Type.PrintTitle).FontSize(15).Bold().Underline().LetterSpacing(0.08f);

                void Para(Action<TextDescriptor> body) => col.Item().Text(t => { t.Justify(); body(t); });
                void PhotoPara(Action<TextDescriptor> body) => col.Item().Row(r =>
                {
                    r.RelativeItem().Text(t => { t.Justify(); body(t); });
                    var box = r.ConstantItem(30, Unit.Millimetre).PaddingLeft(8).Height(36, Unit.Millimetre).Border(1).BorderColor(Line);
                    if (img.Photo != null) box.Image(img.Photo).FitArea();
                    else box.AlignCenter().AlignMiddle().Text("Affix attested\nphotograph").FontSize(8).FontColor(Grey);
                });
                void Grid(int columns, params (string Head, string Value, int Span)[] cells) => col.Item().Table(tb =>
                {
                    tb.ColumnsDefinition(cd => { for (var i = 0; i < columns; i++) cd.RelativeColumn(); });
                    foreach (var (head, value, span) in cells)
                    {
                        if (head.Length > 0) tb.Cell().Border(0.6f).BorderColor(Line).Background("#f3f4f6").Padding(3).Text(head).FontSize(9).Bold();
                        tb.Cell().ColumnSpan((uint)span).Border(0.6f).BorderColor(Line).Padding(3).Text(value).FontSize(10);
                    }
                });

                switch (c.TypeCode)
                {
                    case "FIT":
                        PhotoPara(t =>
                        {
                            t.Span("Certified that I have personally examined "); t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            t.Span($", {gender}, residing at "); t.Span(Blank(p.Address, 30)).Bold(); t.Span(", on "); t.Span(Dt(c.ValidFrom ?? issue)).Bold();
                            if (!string.IsNullOrWhiteSpace(c.PurposeText)) { t.Span(" for the purpose of "); t.Span(c.PurposeText).Bold(); }
                            t.Span(".");
                        });
                        Grid(6,
                            ("Height", Blank(m.B("height"), 6) + " cm", 1), ("Weight", Blank(m.B("weight"), 6) + " kg", 1), ("Blood pressure", Blank(m.B("bp"), 8) + " mmHg", 1),
                            ("Pulse", Blank(m.B("pulse"), 6) + " /min", 1), ("Vision (R / L)", $"{Blank(m.B("visionRight"), 4)} / {Blank(m.B("visionLeft"), 4)}", 1), ("Colour vision", Blank(m.B("colourVision"), 8), 1),
                            ("Hearing", Blank(m.B("hearing"), 8), 1), ("Identification marks", $"1. {Blank(m.B("idMark1"), 20)}   2. {Blank(m.B("idMark2"), 20)}", 3));
                        Para(t => t.Span(string.IsNullOrWhiteSpace(m.B("findings"))
                            ? "On examination, the person was not found to be suffering from any communicable disease or physical or mental disability that would interfere with the stated purpose."
                            : m.B("findings")));
                        if (!string.IsNullOrWhiteSpace(c.Diagnosis)) Para(t => { t.Span("Diagnosis / observations: "); t.Span(c.Diagnosis).Bold(); });
                        Para(t =>
                        {
                            t.Span("In my opinion, he / she is "); t.Span(verdict).Bold();
                            if (!string.IsNullOrWhiteSpace(m.B("restrictions"))) t.Span($" ({m.B("restrictions")})");
                            if (c.ValidTo != null) t.Span($". This certificate is valid till {Dt(c.ValidTo)}");
                            t.Span(".");
                        });
                        break;

                    case "SICK":
                        Para(t =>
                        {
                            t.Span("I, Dr. "); t.Span(docName).Bold(); t.Span(", after careful personal examination of the case, hereby certify that ");
                            t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            if (!string.IsNullOrWhiteSpace(m.B("designation"))) t.Span(", " + m.B("designation"));
                            if (!string.IsNullOrWhiteSpace(m.B("employer"))) t.Span(", " + m.B("employer"));
                            t.Span(", whose signature is given below, is suffering from "); t.Span(Blank(c.Diagnosis, 24)).Bold();
                            t.Span(", and I consider that a period of absence from duty of "); t.Span(days > 0 ? days.ToString() : "____").Bold();
                            t.Span(" day(s) with effect from "); t.Span(Dt(c.ValidFrom)).Bold(); t.Span(" to "); t.Span(Dt(c.ValidTo)).Bold();
                            t.Span(" is absolutely necessary for the restoration of his / her health.");
                        });
                        Para(t =>
                        {
                            t.Span("Rest advised: "); t.Span(Blank(m.B("restAdvised"), 16)).Bold(); t.Span(".");
                            if (!string.IsNullOrWhiteSpace(c.PurposeText)) t.Span(" Issued for: " + c.PurposeText + ".");
                        });
                        col.Item().PaddingTop(14).Text("Signature / thumb impression of the patient: ______________________");
                        break;

                    case "RESUME":
                        Para(t =>
                        {
                            t.Span("I, Dr. "); t.Span(docName).Bold(); t.Span(", do hereby certify that I have carefully examined "); t.Span(name).Bold();
                            t.Span($"{relation}, aged "); t.Span(age).Bold();
                            if (!string.IsNullOrWhiteSpace(m.B("designation"))) t.Span(", " + m.B("designation"));
                            t.Span(", whose signature is given below, who was under my treatment for "); t.Span(Blank(c.Diagnosis, 24)).Bold();
                            t.Span(" from "); t.Span(Dt(c.ValidFrom)).Bold(); t.Span(" to "); t.Span(Dt(c.ValidTo)).Bold();
                            if (!string.IsNullOrWhiteSpace(m.B("leaveCertNo"))) t.Span($" (medical certificate no. {m.B("leaveCertNo")})");
                            t.Span(", and find that he / she has recovered from the illness and is now fit to resume duties with effect from ");
                            t.Span(Bd("resumeOn")).Bold(); t.Span(".");
                        });
                        col.Item().PaddingTop(14).Text("Signature / thumb impression of the patient: ______________________");
                        break;

                    case "VACC":
                        Para(t =>
                        {
                            t.Span("This is to certify that "); t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            t.Span($", {gender}, Patient ID "); t.Span(p.PatientCode).Bold();
                            t.Span(", has received the following vaccine(s) at this hospital / as recorded below");
                            if (!string.IsNullOrWhiteSpace(c.PurposeText)) t.Span(", for the purpose of " + c.PurposeText);
                            t.Span(".");
                        });
                        col.Item().Table(tb =>
                        {
                            tb.ColumnsDefinition(cd =>
                            {
                                cd.ConstantColumn(18); cd.RelativeColumn(3); cd.ConstantColumn(30); cd.RelativeColumn(2); cd.RelativeColumn(2);
                                cd.RelativeColumn(2); cd.RelativeColumn(1.4f); cd.RelativeColumn(2); cd.RelativeColumn(2);
                            });
                            foreach (var head in new[] { "#", "Vaccine", "Dose", "Date given", "Batch / Lot no.", "Manufacturer", "Expiry", "Route / site", "Next due" })
                                tb.Cell().Border(0.6f).BorderColor(Line).Background("#f3f4f6").Padding(3).Text(head).FontSize(8).Bold();
                            var i = 0;
                            foreach (var v in m.Vaccinations)
                            {
                                foreach (var cell in new[]
                                {
                                    (++i).ToString(), v.VaccineName, v.DoseNo.ToString(), Dt(v.GivenOn), v.BatchNo ?? "", v.Manufacturer ?? "",
                                    v.ExpiryDate?.ToString("MM/yyyy") ?? "", v.Route + (string.IsNullOrWhiteSpace(v.Site) ? "" : " / " + v.Site),
                                    v.NextDueDate?.ToString("dd/MM/yyyy") ?? ""
                                })
                                    tb.Cell().Border(0.6f).BorderColor(Line).Padding(3).Text(cell).FontSize(9);
                            }
                            if (m.Vaccinations.Count == 0)
                                tb.Cell().ColumnSpan(9).Border(0.6f).BorderColor(Line).Padding(3).AlignCenter().Text("No doses recorded.").FontSize(9);
                        });
                        break;

                    case "DIS":
                        PhotoPara(t =>
                        {
                            t.Span("This is to certify that I have examined "); t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            t.Span($", {gender}, residing at "); t.Span(Blank(p.Address, 30)).Bold(); t.Span(", Patient ID "); t.Span(p.PatientCode).Bold();
                            if (!string.IsNullOrWhiteSpace(m.B("udid"))) t.Span(", UDID No. " + m.B("udid"));
                            t.Span(", on "); t.Span(Dt(c.ValidFrom ?? issue)).Bold(); t.Span(".");
                        });
                        var rows = new List<(string, string, int)>
                        {
                            ("Specified disability (RPwD Act, 2016)", Blank(m.DisabilityName, 20), 2),
                            ("Diagnosis / cause", c.Diagnosis ?? "", 2),
                            ("Part of body / function affected", m.B("bodyPart"), 2),
                            ("Assessed disability", $"{m.B("percentage")} % ({m.B("nature")})", 2)
                        };
                        if (c.ValidTo != null) rows.Add(("Re-assessment due", Dt(c.ValidTo), 2));
                        rows.Add(("Clinical findings", m.B("findings"), 2));
                        rows.Add(("Recommendation", string.IsNullOrWhiteSpace(m.B("recommendation"))
                            ? "Referred to the medical authority notified by the State Government for the disability certificate." : m.B("recommendation"), 2));
                        Grid(3, rows.ToArray());
                        col.Item().Text($"This is a medical assessment report. It is not a disability certificate under Rule 18 of the RPwD Rules, 2017{(m.DisabilityForm is { } frm ? " (Form " + frm + ")" : "")}, which is issued by the notified medical authority.")
                            .FontSize(9.5f).Italic();
                        break;

                    case "ATTEND":
                        Para(t =>
                        {
                            t.Span("This is to certify that "); t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            t.Span(", Patient ID "); t.Span(p.PatientCode).Bold(); t.Span(", attended the Out-Patient Department of this hospital ");
                            if (c.ValidFrom != null && c.ValidTo != null && c.ValidTo != c.ValidFrom)
                            { t.Span("from "); t.Span(Dt(c.ValidFrom)).Bold(); t.Span(" to "); t.Span(Dt(c.ValidTo)).Bold(); }
                            else { t.Span("on "); t.Span(Dt(c.ValidFrom ?? m.Visit?.VisitDate ?? issue)).Bold(); }
                            if (!string.IsNullOrWhiteSpace(m.B("timeIn"))) t.Span($" from {m.B("timeIn")} to {Blank(m.B("timeOut"), 6)} hours");
                            if (!string.IsNullOrWhiteSpace(c.Diagnosis)) t.Span(" for " + c.Diagnosis);
                            if (!string.IsNullOrWhiteSpace(m.B("accompaniedBy"))) t.Span(", accompanied by " + m.B("accompaniedBy"));
                            t.Span(".");
                        });
                        if (!string.IsNullOrWhiteSpace(c.PurposeText)) Para(t => { t.Span("This certificate is issued on request for: "); t.Span(c.PurposeText).Bold(); t.Span("."); });
                        break;

                    default:
                        Para(t =>
                        {
                            t.Span("This is to certify that "); t.Span(name).Bold(); t.Span($"{relation}, aged "); t.Span(age).Bold();
                            t.Span($", {gender}, Patient ID "); t.Span(p.PatientCode).Bold(); t.Span(", has been under my treatment ");
                            if (c.ValidFrom != null) { t.Span("from "); t.Span(Dt(c.ValidFrom)).Bold(); }
                            if (c.ValidTo != null) { t.Span(" to "); t.Span(Dt(c.ValidTo)).Bold(); }
                            t.Span(" for "); t.Span(Blank(c.Diagnosis, 24)).Bold(); t.Span(".");
                        });
                        if (!string.IsNullOrWhiteSpace(m.B("treatment"))) Para(t => t.Span("Treatment given: " + m.B("treatment")));
                        if (!string.IsNullOrWhiteSpace(m.B("advice"))) Para(t => t.Span("Advice: " + m.B("advice")));
                        if (!string.IsNullOrWhiteSpace(c.PurposeText)) Para(t => { t.Span("This certificate is issued on request for: "); t.Span(c.PurposeText).Bold(); t.Span("."); });
                        break;
                }

                if (!string.IsNullOrWhiteSpace(c.Remarks)) Para(t => t.Span("Remarks: " + c.Remarks));

                // QR · stamp · doctor's signature block
                col.Item().PaddingTop(18).Row(r =>
                {
                    r.ConstantItem(26, Unit.Millimetre).Column(q =>
                    {
                        if (qr != null)
                        {
                            q.Item().Width(24, Unit.Millimetre).Image(qr);
                            q.Item().AlignCenter().Text("Scan to verify").FontSize(7.5f).FontColor(Grey);
                        }
                    });
                    r.RelativeItem().AlignCenter().AlignBottom().Element(e =>
                    {
                        if (img.Stamp != null) e.Height(22, Unit.Millimetre).Image(img.Stamp).FitArea();
                    });
                    r.ConstantItem(70, Unit.Millimetre).AlignBottom().Column(s =>
                    {
                        s.Item().Height(15, Unit.Millimetre).AlignRight().AlignBottom().Element(e =>
                        {
                            if (img.Signature != null && c.Status == "I") e.Image(img.Signature).FitArea();
                        });
                        s.Item().AlignRight().Text("______________________________");
                        s.Item().AlignRight().Text(d?.DoctorName ?? "Signature of the Medical Officer").Bold().FontSize(10.5f);
                        if (!string.IsNullOrWhiteSpace(d?.Qualification)) s.Item().AlignRight().Text(d.Qualification).FontSize(10);
                        if (!string.IsNullOrWhiteSpace(regNo))
                            s.Item().AlignRight().Text($"Regn. No.: {regNo}{(string.IsNullOrWhiteSpace(d?.RegistrationCouncil) ? "" : ", " + d.RegistrationCouncil)}{(d?.RegistrationYear is int y ? $" ({y})" : "")}").FontSize(10);
                        s.Item().AlignRight().Text(m.HospitalName ?? "").FontSize(10);
                    });
                });
            });

            page.Footer().BorderTop(0.6f).BorderColor("#d1d5db").PaddingTop(4).DefaultTextStyle(x => x.FontSize(8).FontColor(Grey)).Column(fc =>
            {
                if (!string.IsNullOrWhiteSpace(m.Type.LegalNote)) fc.Item().Text(m.Type.LegalNote);
                fc.Item().Text($"Computer-generated certificate{(m.VerifyUrl != null ? ". Verify at " + m.VerifyUrl : "")}.");
            });
        }));
    }
}
