using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

// ─── Entry / Edit form ────────────────────────────────────────────────────────
public class VitalEntryViewModel
{
    public int PatientVitalId { get; set; }   // 0 = new

    // Patient context (readonly display)
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientFullName { get; set; }
    public string? PatientAge { get; set; }
    public string? PatientGender { get; set; }
    public string? PatientBloodGroup { get; set; }
    public string? PatientPhone { get; set; }
    public string? PatientAddress { get; set; }

    // ── Anthropometric ──────────────────────────────────────────────
    [Display(Name = "Height (cm)")]
    [Range(30, 250, ErrorMessage = "Height must be 30–250 cm")]
    public decimal? Height { get; set; }

    [Display(Name = "Weight (kg)")]
    [Range(1, 300, ErrorMessage = "Weight must be 1–300 kg")]
    public decimal? Weight { get; set; }

    // Calculated, no user input
    public decimal? BMI { get; set; }
    public string? BMICategory { get; set; }

    // ── Cardiovascular ──────────────────────────────────────────────
    [Display(Name = "Systolic BP (mmHg)")]
    [Range(50, 250, ErrorMessage = "Value 50–250")]
    public int? BPSystolic { get; set; }

    [Display(Name = "Diastolic BP (mmHg)")]
    [Range(30, 150, ErrorMessage = "Value 30–150")]
    public int? BPDiastolic { get; set; }

    [Display(Name = "Pulse Rate (bpm)")]
    [Range(20, 250, ErrorMessage = "Value 20–250")]
    public int? PulseRate { get; set; }

    [Display(Name = "SpO₂ (%)")]
    [Range(50, 100, ErrorMessage = "Value 50–100")]
    public decimal? SpO2 { get; set; }

    // ── General ─────────────────────────────────────────────────────
    [Display(Name = "Temperature (°F)")]
    [Range(90, 115, ErrorMessage = "Value 90–115 °F")]
    public decimal? Temperature { get; set; }

    [Display(Name = "Respiratory Rate")]
    [Range(1, 80, ErrorMessage = "Value 1–80")]
    public int? RespiratoryRate { get; set; }

    // ── Optional ────────────────────────────────────────────────────
    [Display(Name = "Blood Glucose (mg/dL)")]
    [Range(20, 600, ErrorMessage = "Value 20–600")]
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
