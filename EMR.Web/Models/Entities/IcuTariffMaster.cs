using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("IcuTariffMaster", Schema = "dbo")]
public class IcuTariffMaster
{
    [Key]
    public int IcuTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int IcuId { get; set; }

    public int TariffCategoryId { get; set; }

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

    [ForeignKey(nameof(IcuId))]
    public virtual IcuMaster? Icu { get; set; }

    [ForeignKey(nameof(TariffCategoryId))]
    public virtual TariffCategoryMaster? TariffCategory { get; set; }

    public virtual ICollection<IcuTariffDetail> Details { get; set; } = new List<IcuTariffDetail>();
}
