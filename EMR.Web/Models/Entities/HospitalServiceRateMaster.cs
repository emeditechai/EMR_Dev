using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HospitalServiceRateMaster", Schema = "dbo")]
public class HospitalServiceRateMaster
{
    [Key]
    public int ServiceRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    public int BranchId { get; set; }

    [Required]
    public int TariffCategoryId { get; set; }

    [Required]
    public int HospitalServiceId { get; set; }

    [Required]
    [Column(TypeName = "decimal(18,2)")]
    public decimal Rate { get; set; } = 0;

    [Required]
    public DateTime EffectiveFrom { get; set; }

    public DateTime? EffectiveTo { get; set; }

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation / Display helpers
    [ForeignKey(nameof(BranchId))]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey(nameof(TariffCategoryId))]
    public virtual TariffCategoryMaster? TariffCategory { get; set; }

    [ForeignKey(nameof(HospitalServiceId))]
    public virtual HospitalServiceMaster? HospitalService { get; set; }
}
