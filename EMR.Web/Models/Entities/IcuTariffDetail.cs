using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("IcuTariffDetail", Schema = "dbo")]
public class IcuTariffDetail
{
    [Key]
    public int IcuTariffDetailId { get; set; }

    [Required]
    public int IcuTariffId { get; set; }

    [Required]
    [StringLength(100)]
    public string RateHeadName { get; set; } = string.Empty;

    [StringLength(50)]
    public string? RateHeadCode { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal RateAmount { get; set; }

    [Required]
    [StringLength(50)]
    public string BillingFrequency { get; set; } = "Per Day"; // Per Day, Per Hour, Per Usage, Fixed

    public bool IsMandatory { get; set; } = true;

    [StringLength(200)]
    public string? Remarks { get; set; }

    public int DisplayOrder { get; set; } = 0;

    // Navigation property
    [ForeignKey(nameof(IcuTariffId))]
    public virtual IcuTariffMaster? Tariff { get; set; }
}
