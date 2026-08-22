using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("InsuranceTariffMaster", Schema = "dbo")]
public class InsuranceTariffMaster
{
    [Key]
    public int InsTariff_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required]
    [Column("InsuranceTPA_ID")]
    public int InsuranceTPA_ID { get; set; }

    [Required, MaxLength(50)]
    public string EntitlementType { get; set; } = "Procedure"; // Room, Package, Procedure, HospitalService, NonPayableItem

    [Required]
    public int Reference_ID { get; set; }

    [Required, MaxLength(100)]
    public string DeductionRuleType { get; set; } = "Standard Tariff";

    [Column(TypeName = "decimal(18,2)")]
    public decimal DeductionValue { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal Rate { get; set; } = 0;

    public DateTime Effective_From { get; set; }

    public DateTime Effective_To { get; set; }

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation properties
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey("InsuranceTPA_ID")]
    public virtual InsuranceTPAMaster? InsuranceTPA { get; set; }
}
