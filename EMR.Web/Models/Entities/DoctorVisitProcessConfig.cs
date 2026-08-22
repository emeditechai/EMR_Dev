using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorVisitProcessConfig", Schema = "dbo")]
public class DoctorVisitProcessConfig
{
    [Key]
    public int ProcessConfigId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    public int? SpecialityId { get; set; }

    public int? DoctorId { get; set; }

    [Required, MaxLength(50)]
    public string VisitType { get; set; } = "All";

    [Required, MaxLength(50)]
    public string PaymentTiming { get; set; } = "Before Consultation";

    public bool VitalsRequired { get; set; } = true;

    public bool DiagnosisRequired { get; set; } = true;

    public bool Icd10Required { get; set; } = true;

    public bool ProcedureAllowed { get; set; } = true;

    public bool BillingRequired { get; set; } = true;

    public bool PaymentBeforeClosure { get; set; } = true;

    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    public DateTime? EffectiveTo { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? CreatedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    public int? ModifiedBy { get; set; }
}
