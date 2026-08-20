using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("OtTariffMaster", Schema = "dbo")]
public class OtTariffMaster
{
    [Key]
    public int OtTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int TariffCategoryId { get; set; }

    public int OtId { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal OtUsageRate { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal NursingCharges { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal EquipmentCharges { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal RecoveryCharges { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal ConsumableCharges { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal SpecialEquipmentCharges { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal TotalRate { get; set; }

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

    [ForeignKey(nameof(OtId))]
    public virtual OtMaster? Ot { get; set; }
}
