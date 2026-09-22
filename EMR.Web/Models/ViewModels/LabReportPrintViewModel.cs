namespace EMR.Web.Models.ViewModels;

/// <summary>Everything the printable Lab Report page needs (letterhead, patient/specimen/client boxes, results and signatories).</summary>
public class LabReportPrintViewModel
{
    // ── Letterhead ────────────────────────────────────────────────────────────
    public string HospitalName { get; set; } = "eMeditech Hospital";
    public string? HospitalLogoPath { get; set; }
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public string? HospitalWebsite { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? NabhLine { get; set; }

    // ── Patient ───────────────────────────────────────────────────────────────
    public string PatientName { get; set; } = string.Empty;
    public string AgeGender { get; set; } = string.Empty;
    public string? PatientPhone { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientAddress { get; set; }

    // ── Specimen ──────────────────────────────────────────────────────────────
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public string? Barcodes { get; set; }
    public DateTime? Collected { get; set; }
    public DateTime? Received { get; set; }
    public DateTime? Reported { get; set; }

    // ── Client / Doctor ───────────────────────────────────────────────────────
    /// <summary>"Branch" (B2C billing), "Franchise" or "Company" (B2B) - drives the Client box labels.</summary>
    public string ClientLabel { get; set; } = "Branch";
    public string ClientBoxTitle => $"{ClientLabel} / Doctor Information";
    public string? ClientCode { get; set; }
    public string? ClientName { get; set; }
    public string? ClientAddress { get; set; }
    public string? ClientPhone { get; set; }
    public string RefDoctor { get; set; } = "Self";

    // ── Report state ──────────────────────────────────────────────────────────
    /// <summary>True when every active test of the order is approved (=> "Final Report").</summary>
    public bool IsFinal { get; set; }
    /// <summary>True when any test on the printout is validated but not yet approved (=> "NOT APPROVED" watermark).</summary>
    public bool ShowNotApprovedWatermark { get; set; }
    /// <summary>
    /// Final once every test printed here is approved. "(Partial)" is added while other tests of the same bill are
    /// still to be reported, so a final report never implies the whole bill is complete.
    /// </summary>
    public string ReportStatusText => IsFinal
        ? (ExcludedTestCount > 0 ? "Final Report (Partial)" : "Final Report")
        : "Provisional Report";
    public bool HasCritical { get; set; }
    public int IncludedTestCount { get; set; }
    /// <summary>Active tests that are not on this printout yet (pending / submitted / re-collect / rejected).</summary>
    public int ExcludedTestCount { get; set; }

    public List<LabReportSection> Sections { get; set; } = new();

    /// <summary>
    /// Conditions of Reporting from the master (company / branch wise).
    /// null = never configured, so the PDF uses its built-in text; empty = configured but all inactive, so the page is omitted.
    /// </summary>
    public List<string>? Conditions { get; set; }

    // ── Sign-off / footer ─────────────────────────────────────────────────────
    public List<LabReportSignatory> ValidatedBy { get; set; } = new();
    public List<LabReportSignatory> ApprovedBy { get; set; } = new();
    /// <summary>
    /// The Pathologist Approval Flow levels already signed, in level order. Each one prints its own signature
    /// block (image, name, designation, registration number) at the foot of the report.
    /// </summary>
    public List<LabReportLevelSignatory> LevelSignatories { get; set; } = new();
    public string? ProcessingLabName { get; set; }
    public string? ProcessingLabAddress { get; set; }
    /// <summary>1 = original, 2+ = reprint of the same bill (prints a DUPLICATE marker).</summary>
    public int PrintSequence { get; set; } = 1;
    public bool IsDuplicate => PrintSequence > 1;
    public string PrintedBy { get; set; } = string.Empty;
    public DateTime PrintedOn { get; set; } = DateTime.Now;
}

/// <summary>One department + test category. Every section starts on a new printed page.</summary>
public class LabReportSection
{
    public string DepartmentName { get; set; } = string.Empty;
    public string CategoryName { get; set; } = string.Empty;
    public List<LabReportGroup> Groups { get; set; } = new();
}

/// <summary>A package heading, a profile heading, or a standalone investigation, with its result rows.</summary>
public class LabReportGroup
{
    /// <summary>Set only on the first group of a package - printed as a package banner above it.</summary>
    public string? PackageHeading { get; set; }
    /// <summary>Profile / investigation heading. Null for tests that sit directly under a package.</summary>
    public string? Title { get; set; }
    public string? SampleType { get; set; }
    public List<LabReportRow> Rows { get; set; } = new();
    /// <summary>Interpretation / lab remarks printed under the group.</summary>
    public List<string> Notes { get; set; } = new();
}

public class LabReportRow
{
    public string TestName { get; set; } = string.Empty;
    public string Result { get; set; } = string.Empty;
    /// <summary>"H", "L", "*" (critical) or a combination such as "* H"; empty when normal.</summary>
    public string FlagText { get; set; } = string.Empty;
    public bool IsAbnormal { get; set; }
    public bool IsCritical { get; set; }
    public string RefRange { get; set; } = string.Empty;
    public string Unit { get; set; } = string.Empty;
    public string Method { get; set; } = string.Empty;
    /// <summary>False when the row is validated but not yet approved.</summary>
    public bool IsApproved { get; set; }
    public bool IsLongText { get; set; }
}

public class LabReportSignatory
{
    public string Name { get; set; } = string.Empty;
    public string? Qualification { get; set; }
    public string? RegistrationNo { get; set; }
}

/// <summary>One signed approval level of the Pathologist Approval Flow, with the signatory's signature image.</summary>
public class LabReportLevelSignatory
{
    public int LevelNo { get; set; }
    public int TotalLevels { get; set; }
    public string? LevelTitle { get; set; }
    public bool IsFinalLevel { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Qualification { get; set; }
    public string? RegistrationNo { get; set; }
    /// <summary>When the level was signed; null for a signatory configured in Hospital Settings (never signed).</summary>
    public DateTime? SignedOn { get; set; }
    /// <summary>The uploaded signature image (png/jpg); null when the pathologist has not uploaded one.</summary>
    public byte[]? SignatureImage { get; set; }
}
