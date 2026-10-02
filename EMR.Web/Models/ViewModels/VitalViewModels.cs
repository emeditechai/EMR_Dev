using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

// ─── Entry / Edit form ────────────────────────────────────────────────────────
public class VitalEntryViewModel
{
    public int PatientVitalId { get; set; }   // 0 = new
    public string? ReturnUrl { get; set; }

    // Patient context (readonly display)
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientFullName { get; set; }
    public string? PatientAge { get; set; }
    public string? PatientGender { get; set; }
    public string? PatientBloodGroup { get; set; }
    public string? PatientPhone { get; set; }
    public string? PatientAddress { get; set; }

    // Only what the database can store is enforced here (no negatives, fits the column). Clinical ranges are
    // warnings on the form - an unusual value can still be saved after the user confirms it.

    // ── Anthropometric ──────────────────────────────────────────────
    [Display(Name = "Height (cm)")]
    [Range(0, 9999.99, ErrorMessage = "Height must be a positive number.")]
    public decimal? Height { get; set; }

    [Display(Name = "Weight (kg)")]
    [Range(0, 9999.99, ErrorMessage = "Weight must be a positive number.")]
    public decimal? Weight { get; set; }

    // Calculated, no user input
    public decimal? BMI { get; set; }
    public string? BMICategory { get; set; }

    // ── Cardiovascular ──────────────────────────────────────────────
    [Display(Name = "Systolic BP (mmHg)")]
    [Range(0, 9999, ErrorMessage = "Systolic BP must be a positive number.")]
    public int? BPSystolic { get; set; }

    [Display(Name = "Diastolic BP (mmHg)")]
    [Range(0, 9999, ErrorMessage = "Diastolic BP must be a positive number.")]
    public int? BPDiastolic { get; set; }

    [Display(Name = "Pulse Rate (bpm)")]
    [Range(0, 9999, ErrorMessage = "Pulse must be a positive number.")]
    public int? PulseRate { get; set; }

    [Display(Name = "SpO₂ (%)")]
    [Range(0, 100, ErrorMessage = "SpO₂ is a percentage: 0–100.")]
    public decimal? SpO2 { get; set; }

    // ── General ─────────────────────────────────────────────────────
    [Display(Name = "Temperature (°F)")]
    [Range(0, 999.99, ErrorMessage = "Temperature must be a positive number.")]
    public decimal? Temperature { get; set; }

    [Display(Name = "Respiratory Rate")]
    [Range(0, 9999, ErrorMessage = "Respiratory rate must be a positive number.")]
    public int? RespiratoryRate { get; set; }

    // ── Optional ────────────────────────────────────────────────────
    [Display(Name = "Blood Glucose (mg/dL)")]
    [Range(0, 99999.99, ErrorMessage = "Blood glucose must be a positive number.")]
    public decimal? BloodGlucose { get; set; }

    [Display(Name = "Glucose Type")]
    public string? GlucoseType { get; set; }    // Fasting / Random / PP

    [Display(Name = "Pain Score (0–10)")]
    [Range(0, 10, ErrorMessage = "Value 0–10")]
    public int? PainScore { get; set; }

    [Display(Name = "Notes")]
    [MaxLength(500)]
    public string? Notes { get; set; }
}

// ─── History row (returned from DB) ──────────────────────────────────────────
public class VitalHistoryRow
{
    public int PatientVitalId { get; set; }
    public int PatientId { get; set; }

    public decimal? Height { get; set; }
    public decimal? Weight { get; set; }
    public decimal? BMI { get; set; }
    public string? BMICategory { get; set; }
    public int? BPSystolic { get; set; }
    public int? BPDiastolic { get; set; }
    public int? PulseRate { get; set; }
    public decimal? SpO2 { get; set; }
    public decimal? Temperature { get; set; }
    public int? RespiratoryRate { get; set; }
    public decimal? BloodGlucose { get; set; }
    public string? GlucoseType { get; set; }
    public int? PainScore { get; set; }
    public string? Notes { get; set; }
    public DateTime RecordedOn { get; set; }
    public string? RecordedByName { get; set; }
    public int TotalCount { get; set; }
    public bool CanModify { get; set; }
}

// ─── Print page view model ────────────────────────────────────────────────────
public class VitalPrintViewModel
{
    // Hospital
    public string HospitalName    { get; set; } = "Hospital";
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone   { get; set; }
    public string? HospitalEmail   { get; set; }
    public string? HospitalWebsite { get; set; }
    public string? HospitalLogo    { get; set; }

    // Patient
    public int    PatientId       { get; set; }
    public string PatientCode     { get; set; } = string.Empty;
    public string PatientFullName { get; set; } = string.Empty;
    public string? PatientAge     { get; set; }
    public string? PatientGender  { get; set; }
    public string? PatientBloodGroup { get; set; }
    public string? PatientAddress { get; set; }
    public string? PatientPhone   { get; set; }
    public string? LastOpdBillNo  { get; set; }

    // Vital (latest)
    public VitalHistoryRow? Vital { get; set; }
}

// ─── Index / history page ─────────────────────────────────────────────────────
public class VitalIndexViewModel
{
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientFullName { get; set; }
    public string? PatientAge { get; set; }
    public string? PatientGender { get; set; }
    public string? PatientBloodGroup { get; set; }
    public string? PatientPhone { get; set; }

    public List<VitalHistoryRow> Vitals { get; set; } = [];
    public int TotalCount { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 10;
}
