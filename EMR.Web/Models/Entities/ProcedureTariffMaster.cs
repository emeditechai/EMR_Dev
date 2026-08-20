using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ProcedureTariffMaster", Schema = "dbo")]
public class ProcedureTariffMaster
{
    [Key]
    public int ProcedureTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int TariffCategoryId { get; set; }

    public int ProcedureId { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal SurgeonFee { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal AssistantFee { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal AnaesthetistFee { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal OtCharges { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal EquipmentCharges { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal ConsumableCharges { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal NursingCharges { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal TotalRate { get; set; } = 0;

    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? ModifiedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    // Navigation properties
    [ForeignKey(nameof(BranchId))]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey(nameof(TariffCategoryId))]
    public virtual TariffCategoryMaster? TariffCategory { get; set; }

    [ForeignKey(nameof(ProcedureId))]
    public virtual ProcedureMaster? Procedure { get; set; }
}
