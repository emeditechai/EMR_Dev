namespace EMR.Web.Models.Entities;

/// <summary>
/// OPD Bill header — one row per visit/bill.
/// Line items are in PatientOPDServiceItem.
/// </summary>
public class PatientOPDService
{
    public int OPDServiceId { get; set; }

    public int PatientId { get; set; }

    public int? BranchId { get; set; }

    public int? ConsultingDoctorId { get; set; }

    /// <summary>Generated bill number: OP&lt;FY&gt;&lt;6-digit seq&gt; e.g. OP2526000001</summary>
    public string? OPDBillNo { get; set; }

    /// <summary>Day-wise token: OPD-0042</summary>
    public string? TokenNo { get; set; }

    public decimal? TotalAmount { get; set; }

    public DateTime VisitDate { get; set; } = DateTime.Now;

    /// <summary>Registered | Completed | Cancelled</summary>
    public string Status { get; set; } = "Registered";

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation
    public PatientMaster? Patient { get; set; }
    public List<PatientOPDServiceItem> Items { get; set; } = [];
}
