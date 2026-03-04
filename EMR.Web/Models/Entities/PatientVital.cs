using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class PatientVital
{
    public int PatientVitalId { get; set; }
    public int PatientId { get; set; }

    // Anthropometric
    public decimal? Height { get; set; }          // cm
    public decimal? Weight { get; set; }          // kg
    public decimal? BMI { get; set; }             // kg/m²
    public string? BMICategory { get; set; }

    // Cardiovascular
    public int? BPSystolic { get; set; }          // mmHg
    public int? BPDiastolic { get; set; }         // mmHg
    public int? PulseRate { get; set; }           // bpm
    public decimal? SpO2 { get; set; }            // %

    // General
    public decimal? Temperature { get; set; }     // °F
    public int? RespiratoryRate { get; set; }     // breaths/min

    // Optional
    public decimal? BloodGlucose { get; set; }    // mg/dL
    public string? GlucoseType { get; set; }      // Fasting / Random / PP
    public int? PainScore { get; set; }           // 0–10

    public string? Notes { get; set; }

    // Audit
    public DateTime RecordedOn { get; set; } = DateTime.UtcNow;
    public int? RecordedByUserId { get; set; }
    public string? RecordedByName { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedOn { get; set; } = DateTime.UtcNow;
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public int? UpdatedBy { get; set; }

    // For paged list
    public int TotalCount { get; set; }
}
