using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("CorporateMaster", Schema = "dbo")]
public class CorporateMaster
{
    [Key]
    public int Corporate_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [MaxLength(50)]
    public string? Corporate_Code { get; set; }

    [Required, MaxLength(200)]
    public string Corporate_Name { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string Corporate_Type { get; set; } = "ALL";

    public DateTime Effective_From { get; set; }

    public DateTime Effective_To { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal? Credit_Limit { get; set; }

    public int? Credit_Days { get; set; }

    [Required, MaxLength(50)]
    public string BillingCycle { get; set; } = "Monthly";

    [Required, MaxLength(20)]
    public string Contact_No { get; set; } = string.Empty;

    [MaxLength(150)]
    public string? Email { get; set; }

    [MaxLength(500)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? Pincode { get; set; }

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation property
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }
}
