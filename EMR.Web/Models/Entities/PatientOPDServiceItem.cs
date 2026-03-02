namespace EMR.Web.Models.Entities;

public class PatientOPDServiceItem
{
    public int ItemId { get; set; }

    public int OPDServiceId { get; set; }

    public string? ServiceType { get; set; }   // "Consulting" or "Service"

    public int? ServiceId { get; set; }

    public decimal? ServiceCharges { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;

    // Navigation
    public PatientOPDService? OPDService { get; set; }
}
