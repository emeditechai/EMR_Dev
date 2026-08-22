using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("GovernmentSchemeMaster", Schema = "dbo")]
public class GovernmentSchemeMaster
{
    [Key]
    public int Scheme_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(50)]
    public string SchemeCode { get; set; } = string.Empty;

    [Required, MaxLength(200)]
    public string SchemeName { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string SchemeType { get; set; } = "Central Government"; // Central Government, State Government, Defence / Ex-Servicemen, PSU / Autonomous Body, Social Security / Labour

    [Required, MaxLength(200)]
    public string AuthorityName { get; set; } = string.Empty;

    public string? RuleConfigJSON { get; set; }

    public DateTime Effective_From { get; set; }

    public DateTime Effective_To { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation property
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }
}
