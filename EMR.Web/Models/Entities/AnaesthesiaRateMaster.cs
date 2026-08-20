using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("AnaesthesiaRateMaster", Schema = "dbo")]
public class AnaesthesiaRateMaster
{
    [Key]
    public int AnaesthesiaRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int ProcedureId { get; set; }

    public int AnaesthesiaTypeId { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal AnaesthetistFee { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal ConsumableCharge { get; set; }

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

    [ForeignKey(nameof(ProcedureId))]
    public virtual ProcedureMaster? Procedure { get; set; }

    [ForeignKey(nameof(AnaesthesiaTypeId))]
    public virtual AnaesthesiaTypeMaster? AnaesthesiaType { get; set; }
}
