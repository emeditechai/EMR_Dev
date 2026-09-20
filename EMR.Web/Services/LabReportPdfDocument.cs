using EMR.Web.Models.ViewModels;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace EMR.Web.Services;

/// <summary>
/// Lab Report PDF (QuestPDF). Layout follows the reference lab-report template:
/// letterhead, Patient / Specimen / Client boxes, a Test | Result | Bio. Ref. Range | Unit | Method table,
/// interpretation notes, "End Of Report" sign-off, and a Conditions of Reporting page.
///
/// Every Department + Test Category section is its own PDF page group, so it always starts on a new page.
/// The header, footer ("Page X of Y") and the NOT APPROVED watermark repeat on every page.
/// </summary>
public class LabReportPdfDocument : IDocument
{
    private const float Line = 0.7f;
    private static readonly string Ink = "#111111";
    private static readonly string Navy = "#0f3d6b";
    private static readonly string Grey = "#475569";
    private static readonly string Amber = "#b45309";
    private static readonly string Crimson = "#b91c1c";
    private static readonly string Green = "#166534";

    private readonly LabReportPrintViewModel vm;
    private readonly byte[]? logo;
    private readonly bool includeConditions;

    static LabReportPdfDocument()
    {
        // QuestPDF Community licence (free for organisations under the licence's revenue threshold).
        QuestPDF.Settings.License = LicenseType.Community;
    }

    public LabReportPdfDocument(LabReportPrintViewModel vm, byte[]? logo, bool includeConditions = true)
    {
        this.vm = vm;
        this.logo = logo;
        this.includeConditions = includeConditions;
    }

    /// <summary>Renders the report. If the logo image is unreadable the report is rendered again without it.</summary>
    public static byte[] Generate(LabReportPrintViewModel vm, byte[]? logo, bool includeConditions = true)
    {
        try
        {
            return new LabReportPdfDocument(vm, logo, includeConditions).GeneratePdf();
        }
        catch when (logo != null)
        {
            return new LabReportPdfDocument(vm, null, includeConditions).GeneratePdf();
        }
    }

    public DocumentMetadata GetMetadata() => new()
    {
        Title = $"Lab Report {vm.BillNo}",
        Author = vm.HospitalName,
        Subject = vm.ReportStatusText
    };

    public DocumentSettings GetSettings() => DocumentSettings.Default;

    public void Compose(IDocumentContainer container)
    {
        for (int i = 0; i < vm.Sections.Count; i++)
        {
            var section = vm.Sections[i];
            bool isLast = i == vm.Sections.Count - 1;
            container.Page(page => ComposeSectionPage(page, section, isLast));
        }

        var conditions = vm.Conditions ?? DefaultConditions.ToList();
        if (includeConditions && conditions.Count > 0)
            container.Page(page => ComposeConditionsPage(page, conditions));
    }

    // ═════════════════════════════ page frame ═════════════════════════════

    private void ConfigurePage(PageDescriptor page)
    {
        page.Size(PageSizes.A4);
        page.MarginHorizontal(10, Unit.Millimetre);
        page.MarginTop(8, Unit.Millimetre);
        page.MarginBottom(8, Unit.Millimetre);
        page.DefaultTextStyle(t => t.FontSize(8.5f).FontColor(Ink));
    }

    private void ComposeSectionPage(PageDescriptor page, LabReportSection section, bool isLast)
    {
        ConfigurePage(page);
        page.Header().Element(ComposeHeader);
        page.Content().Element(c => ComposeSection(c, section, isLast));
        page.Footer().Element(ComposeFooter);

        if (vm.ShowNotApprovedWatermark)
            page.Foreground().Element(ComposeWatermark);
    }

    // ═════════════════════════════ header (repeats on every page) ═════════════════════════════

    private void ComposeHeader(IContainer container)
    {
        container.Column(col =>
        {
            // Letterhead
            col.Item().PaddingBottom(4).BorderBottom(1.6f).BorderColor(Navy).Row(row =>
            {
                if (logo != null)
                    row.ConstantItem(64).PaddingRight(6).Height(40).AlignMiddle().Image(logo).FitArea();

                row.RelativeItem().Column(name =>
                {
                    name.Item().Text(vm.HospitalName).FontSize(15).ExtraBold().FontColor(Navy);
                    name.Item().Text("DEPARTMENT OF LABORATORY MEDICINE").FontSize(7.5f).FontColor(Grey).LetterSpacing(0.06f);
                    if (!string.IsNullOrWhiteSpace(vm.NabhLine))
                        name.Item().PaddingTop(1).Text(vm.NabhLine).FontSize(7).SemiBold().FontColor(Navy);
                });

                row.RelativeItem().AlignRight().Column(addr =>
                {
                    void Line(string? text) { if (!string.IsNullOrWhiteSpace(text)) addr.Item().AlignRight().Text(text).FontSize(7.5f).FontColor(Grey); }
                    Line(vm.HospitalAddress);
                    Line(string.IsNullOrWhiteSpace(vm.HospitalPhone) ? null : $"Tel: {vm.HospitalPhone}");
                    Line(vm.HospitalEmail);
                    Line(vm.HospitalWebsite);
                    Line(string.IsNullOrWhiteSpace(vm.RegistrationNumber) ? null : $"Reg. No.: {vm.RegistrationNumber}");

                    // Reprint of a bill already printed once: flagged small, as required for a duplicate copy.
                    if (vm.IsDuplicate)
                        addr.Item().PaddingTop(2).AlignRight().Border(0.6f).BorderColor(Crimson).PaddingHorizontal(3).PaddingVertical(1)
                            .Text($"DUPLICATE COPY · Print #{vm.PrintSequence}").FontSize(6.5f).Bold().FontColor(Crimson).LetterSpacing(0.05f);
                });
            });

            // Patient / Specimen / Client boxes
            col.Item().PaddingTop(4).Border(1.1f).Row(row =>
            {
                row.RelativeItem().BorderRight(1.1f).Element(c => InfoBox(c, "Patient Information", new[]
                {
                    ("Name", vm.PatientName, false),
                    ("Age/Gender", vm.AgeGender, false),
                    ("Mobile No", Or(vm.PatientPhone), false),
                    ("Patient ID", Or(vm.PatientCode), false),
                    ("Address", Or(vm.PatientAddress), false)
                }));

                row.RelativeItem().BorderRight(1.1f).Element(c => InfoBox(c, "Specimen Information", new[]
                {
                    ("Bill No", Or(vm.BillNo), false),
                    ("Collected", Dt(vm.Collected), false),
                    ("Received", Dt(vm.Received), false),
                    ("Reported", Dt(vm.Reported), false),
                    ("Report Status", vm.ReportStatusText, true)
                }));

                row.RelativeItem().Element(c => InfoBox(c, vm.ClientBoxTitle, new[]
                {
                    ($"{vm.ClientLabel} Code", Or(vm.ClientCode), false),
                    ($"{vm.ClientLabel} Name", Or(vm.ClientName), false),
                    ($"{vm.ClientLabel} Add.", Or(vm.ClientAddress), false),
                    ($"{vm.ClientLabel} No.", Or(vm.ClientPhone), false),
                    ("Ref Doctor", vm.RefDoctor, false)
                }));
            });

            // Column headings
            col.Item().PaddingTop(4).Table(table =>
            {
                Columns(table);
                foreach (var h in new[] { "Test Name", "Result", "Bio. Ref. Range", "Unit", "Method" })
                {
                    table.Cell().Background("#d9d9d9").Border(Line).BorderColor(Ink)
                        .PaddingVertical(4).AlignCenter().Text(h).Bold().FontSize(9);
                }
            });
        });
    }

    private void InfoBox(IContainer container, string title, (string Label, string Value, bool IsStatus)[] rows)
    {
        container.Padding(3).Column(col =>
        {
            col.Item().PaddingBottom(2).BorderBottom(0.8f).BorderColor("#999999").Text(title).Bold().FontSize(8.5f);
            foreach (var (label, value, isStatus) in rows)
            {
                col.Item().PaddingTop(1).Row(r =>
                {
                    r.ConstantItem(58).Text(label).FontSize(7.5f).FontColor("#333333");
                    var txt = r.RelativeItem().Text($": {value}").FontSize(7.5f).SemiBold();
                    if (isStatus) txt.FontColor(vm.IsFinal ? Green : Amber);
                });
            }
        });
    }

    // ═════════════════════════════ content ═════════════════════════════

    private static void Columns(TableDescriptor table)
    {
        table.ColumnsDefinition(c =>
        {
            c.RelativeColumn(31);
            c.RelativeColumn(14);
            c.RelativeColumn(17);
            c.RelativeColumn(9);
            c.RelativeColumn(29);
        });
    }

    private void ComposeSection(IContainer container, LabReportSection section, bool isLast)
    {
        container.Column(col =>
        {
            // Department > Category banner
            col.Item().PaddingTop(6).PaddingBottom(1).Text(t =>
            {
                t.Span(section.DepartmentName.ToUpperInvariant()).Bold().FontSize(8).FontColor(Navy).LetterSpacing(0.06f);
                t.Span("  ›  ").FontSize(8).FontColor("#94a3b8");
                t.Span(section.CategoryName.ToUpperInvariant()).Bold().FontSize(8).FontColor(Navy).LetterSpacing(0.06f);
            });

            foreach (var group in section.Groups)
            {
                // Small groups are kept together on one page; long ones (e.g. a big CBC profile) may flow across pages.
                if (group.Rows.Count <= 14)
                    col.Item().ShowEntire().Element(c => ComposeGroup(c, group));
                else
                    col.Item().Element(c => ComposeGroup(c, group));
            }

            if (isLast)
                col.Item().PaddingTop(10).Element(ComposeSignOff);
        });
    }

    private void ComposeGroup(IContainer container, LabReportGroup group)
    {
        container.Column(col =>
        {
            if (!string.IsNullOrWhiteSpace(group.PackageHeading))
            {
                col.Item().PaddingTop(5).Background("#eef2f7").Border(Line).BorderColor(Ink).Padding(3)
                    .Text($"Package: {group.PackageHeading}").Bold().FontSize(9.5f).FontColor(Navy);
            }

            if (!string.IsNullOrWhiteSpace(group.Title))
            {
                col.Item().PaddingTop(7).PaddingBottom(2).EnsureSpace(60).Text(t =>
                {
                    t.Span(group.Title).Bold().FontSize(10);
                    if (!string.IsNullOrWhiteSpace(group.SampleType))
                        t.Span($" , {group.SampleType}").Italic().FontSize(9);
                });
            }

            col.Item().BorderTop(Line).BorderLeft(Line).BorderColor(Ink).Table(table =>
            {
                Columns(table);
                foreach (var row in group.Rows)
                    AddRow(table, row);
            });

            if (group.Notes.Count > 0)
            {
                col.Item().BorderLeft(Line).BorderRight(Line).BorderBottom(Line).BorderColor(Ink)
                    .PaddingHorizontal(6).PaddingVertical(4).Column(n =>
                    {
                        n.Item().Text("Interpretation:").Bold().FontSize(8.5f);
                        foreach (var note in group.Notes)
                        {
                            n.Item().PaddingTop(1).Row(r =>
                            {
                                r.ConstantItem(9).Text("•");
                                r.RelativeItem().Text(note).FontSize(8.5f);
                            });
                        }
                    });
            }
        });
    }

    private void AddRow(TableDescriptor table, LabReportRow row)
    {
        IContainer Cell() => table.Cell().BorderBottom(Line).BorderRight(Line).BorderColor(Ink).PaddingHorizontal(4).PaddingVertical(3).AlignMiddle();

        // Test name (‡ = validated but not yet approved, only on provisional copies)
        Cell().Text(t =>
        {
            t.Span(row.TestName).FontSize(9);
            if (vm.ShowNotApprovedWatermark && !row.IsApproved)
                t.Span(" ‡").Bold().FontColor(Amber);
        });

        // Result (+ H / L / * flag)
        var result = Cell();
        if (row.IsLongText)
            result.AlignLeft().Text(row.Result).FontSize(9);
        else
            result.AlignCenter().Text(t =>
            {
                var main = t.Span(row.Result).FontSize(9.5f);
                if (row.IsAbnormal) main.Bold();
                if (row.IsCritical) main.FontColor(Crimson);
                if (!string.IsNullOrEmpty(row.FlagText))
                {
                    var flag = t.Span($"  {row.FlagText}").Bold().FontSize(9);
                    if (row.IsCritical) flag.FontColor(Crimson);
                }
            });

        Cell().AlignCenter().Text(string.IsNullOrEmpty(row.RefRange) ? "—" : row.RefRange).FontSize(9);
        Cell().AlignCenter().Text(row.Unit).FontSize(9);
        Cell().AlignCenter().Text(row.Method).FontSize(8.5f);
    }

    private void ComposeSignOff(IContainer container)
    {
        container.ShowEntire().Column(col =>
        {
            if (vm.HasCritical)
                col.Item().PaddingBottom(2).Text("If Values are marked with * , they are critical values.").Bold().FontSize(9);

            if (vm.ShowNotApprovedWatermark)
                col.Item().PaddingBottom(2).Text("‡ Validated, awaiting final approval. This copy is not valid for clinical or legal use until approved.")
                    .Bold().FontSize(8.5f).FontColor(Amber);

            col.Item().PaddingVertical(6).AlignCenter().Text("*** End Of Report ***").Bold().FontSize(9.5f);

            col.Item().Row(row =>
            {
                row.RelativeItem().Row(sign =>
                {
                    sign.RelativeItem().Element(c => Signatories(c, "Validated by", vm.ValidatedBy, "—"));
                    sign.RelativeItem().Element(c => Signatories(c, "Approved by", vm.ApprovedBy, "Approval pending"));
                });
            });
        });
    }

    private void Signatories(IContainer container, string role, List<LabReportSignatory> people, string emptyText)
    {
        container.PaddingRight(14).Column(col =>
        {
            col.Item().PaddingBottom(14).BorderBottom(0.7f).BorderColor("#999999")
                .Text(role.ToUpperInvariant()).FontSize(7).FontColor(Grey).LetterSpacing(0.06f);

            if (people.Count == 0)
            {
                col.Item().Text(emptyText).FontSize(8).Italic().FontColor(emptyText == "—" ? Ink : Amber);
                return;
            }

            foreach (var p in people)
            {
                col.Item().Text(p.Name).Bold().FontSize(9);
                if (!string.IsNullOrWhiteSpace(p.Qualification)) col.Item().Text(p.Qualification).FontSize(8);
                if (!string.IsNullOrWhiteSpace(p.RegistrationNo)) col.Item().Text($"Reg. No.: {p.RegistrationNo}").FontSize(8);
            }
        });
    }

    // ═════════════════════════════ footer (repeats on every page) ═════════════════════════════

    private void ComposeFooter(IContainer container)
    {
        container.Column(col =>
        {
            var lab = vm.ProcessingLabName ?? vm.HospitalName;
            var address = string.IsNullOrWhiteSpace(vm.ProcessingLabAddress) ? string.Empty : $", {vm.ProcessingLabAddress}";

            col.Item().BorderTop(0.8f).BorderColor(Ink).PaddingTop(2)
                .Text($"This test has been performed at {lab}{address}").FontSize(7.5f).SemiBold();

            col.Item().Row(row =>
            {
                row.RelativeItem().Text($"Printed on {vm.PrintedOn:dd/MMM/yyyy HH:mm} by {vm.PrintedBy}  |  Bill {vm.BillNo}")
                    .FontSize(7).FontColor(Grey);
                row.ConstantItem(90).AlignRight().Text(t =>
                {
                    t.DefaultTextStyle(s => s.FontSize(7.5f).FontColor(Grey));
                    t.Span("Page ");
                    t.CurrentPageNumber();
                    t.Span(" of ");
                    t.TotalPages();
                });
            });
        });
    }

    // ═════════════════════════════ watermark (every page of a provisional copy) ═════════════════════════════

    private static void ComposeWatermark(IContainer container)
    {
        var faint = Color.FromARGB(48, 220, 38, 38);

        container.AlignCenter().AlignMiddle().Rotate(-32).Border(5).BorderColor(faint).Padding(8).Column(col =>
        {
            col.Item().AlignCenter().Text("NOT APPROVED").FontSize(58).ExtraBold().FontColor(faint).LetterSpacing(0.08f);
            col.Item().AlignCenter().Text("DRAFT COPY — PENDING APPROVAL").FontSize(13).Bold().FontColor(faint).LetterSpacing(0.15f);
        });
    }

    // ═════════════════════════════ conditions of reporting ═════════════════════════════

    /// <summary>Used only when the company has never configured Conditions of Reporting in the master.</summary>
    private static readonly string[] DefaultConditions =
    {
        "The contents of this report are to be forwarded to the referring doctor only, for the purpose of assisting in diagnosis and management of the patient.",
        "Test results relate only to the specimen submitted for testing.",
        "Unless the collection time is specified, the date printed is the date the sample was received.",
        "Interpretation notes, where given, appear below the test heading. Results should be interpreted together with clinical findings and other investigations.",
        "A requested test may not be performed, or may be reported as \"QTY. NOT ADEQUATE\", \"TEST NOT PERFORMED\" or \"INCONCLUSIVE\", when the specimen is insufficient, unsuitable (haemolysed / clotted / lipaemic) or incorrectly labelled. The reason is stated on the report.",
        "A \"PROVISIONAL\" report means some results are not yet authenticated. A provisional copy carries a NOT APPROVED mark and is not valid for clinical or legal use until the final report is issued.",
        "Values marked with * are critical values. H and L indicate results above and below the reference range.",
        "A repeat investigation may be possible as per the laboratory's sample retention policy.",
        "Laboratory results depend on sample quality, assay technology, equipment and method specificity. Isolated laboratory results are not the final diagnosis of disease.",
        "Results may be delayed for reasons beyond the laboratory's control. If a result does not fit the clinical picture, please contact the laboratory for a retest.",
        "Reports are meant to assist in diagnosing medical conditions and are not for forensic or medico-legal purposes."
    };

    private void ComposeConditionsPage(PageDescriptor page, List<string> conditions)
    {
        ConfigurePage(page);
        page.Footer().Element(ComposeFooter);
        if (vm.ShowNotApprovedWatermark)
            page.Foreground().Element(ComposeWatermark);

        page.Content().PaddingTop(10).Column(col =>
        {
            col.Item().PaddingHorizontal(60).Border(1.3f).BorderColor(Ink).PaddingVertical(7)
                .AlignCenter().Text("Conditions of Reporting").Bold().FontSize(16);

            col.Item().PaddingTop(16).Column(list =>
            {
                for (int i = 0; i < conditions.Count; i++)
                {
                    list.Item().PaddingBottom(5).Row(r =>
                    {
                        r.ConstantItem(20).Text($"{i + 1}.").FontSize(9.5f);
                        r.RelativeItem().Text(conditions[i]).FontSize(9.5f).LineHeight(1.35f);
                    });
                }
            });

            col.Item().PaddingTop(18).AlignCenter().Column(lab =>
            {
                lab.Item().AlignCenter().Text(vm.HospitalName).Bold().FontSize(12);
                if (!string.IsNullOrWhiteSpace(vm.HospitalAddress)) lab.Item().AlignCenter().Text(vm.HospitalAddress).FontSize(9.5f);
                var contact = string.Join("  |  ", new[] { vm.HospitalPhone == null ? null : $"Tel: {vm.HospitalPhone}", vm.HospitalEmail }
                    .Where(x => !string.IsNullOrWhiteSpace(x)));
                if (contact.Length > 0) lab.Item().AlignCenter().Text(contact).FontSize(9.5f);
            });
        });
    }

    // ═════════════════════════════ helpers ═════════════════════════════

    private static string Or(string? v) => string.IsNullOrWhiteSpace(v) ? "—" : v;
    private static string Dt(DateTime? d) => d.HasValue ? d.Value.ToString("dd/MMM/yyyy HH:mm") : "—";
}
