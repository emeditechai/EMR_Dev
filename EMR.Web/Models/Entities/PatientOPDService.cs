namespace EMR.Web.Models.Entities;

public class PatientOPDService
{
    public int OPDServiceId { get; set; }

    public int PatientId { get; set; }

    public int? BranchId { get; set; }

    public int? ConsultingDoctorId { get; set; }

    public string? ServiceType { get; set; }      // "Consulting" or "Services"

    public int? ServiceId { get; set; }

    public decimal? ServiceCharges { get; set; }

    public DateTime VisitDate { get; set; } = DateTime.UtcNow;

    /// <summary>Registered | Completed | Cancelled</summary>
    public string Status { get; set; } = "Registered";

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation
    public PatientMaster? Patient { get; set; }
}
