using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorCommissionConfig", Schema = "dbo")]
public class DoctorCommissionConfig
{
    [Key]
    public int CommissionConfigId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    public int? DoctorId { get; set; }

    public int? SpecialityId { get; set; }

    [Required, MaxLength(50)]
    public string RevenueType { get; set; } = "Consultation";

    [Required, MaxLength(50)]
    public string CalculationType { get; set; } = "Percentage";

    [Required, MaxLength(50)]
    public string CommissionBasis { get; set; } = "Net Collected";

    [Column(TypeName = "decimal(18,2)")]
    public decimal DoctorShare { get; set; } = 70.00m;

    public int? ProcedureId { get; set; }

    public int? ServiceId { get; set; }

    public int? CorporateId { get; set; }

    public int? InsuranceTPAId { get; set; }

    public bool ApprovalRequired { get; set; } = true;

    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    public DateTime? EffectiveTo { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? CreatedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    public int? ModifiedBy { get; set; }
}
