using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("CorporateHospitalRateMaster", Schema = "dbo")]
public class CorporateHospitalRateMaster
{
    [Key]
    public int CorpRate_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required]
    [Column("Corporate_ID")]
    public int Corporate_ID { get; set; }

    [Required, MaxLength(50)]
    public string RateServiceType { get; set; } = "Procedure"; // Room, Procedure, OT, ICU, HospitalService, Package

    [Required]
    public int ReferenceMaster_ID { get; set; }

    [Required, MaxLength(50)]
    public string RateType { get; set; } = "Percentage"; // Percentage, Rate, Both

    [Column(TypeName = "decimal(18,2)")]
    public decimal? Rate { get; set; }

    [Column(TypeName = "decimal(5,2)")]
    public decimal? DiscountPercent { get; set; }

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

    [ForeignKey("Corporate_ID")]
    public virtual CorporateMaster? Corporate { get; set; }
}
