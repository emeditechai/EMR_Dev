using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("InsuranceTPAMaster", Schema = "dbo")]
public class InsuranceTPAMaster
{
    [Key]
    public int InsuranceTPA_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(50)]
    public string Type { get; set; } = "Insurance Company"; // 'Insurance Company', 'TPA'

    [Required, MaxLength(200)]
    public string Name { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string Code { get; set; } = string.Empty;

    [MaxLength(200)]
    public string? SchemeName { get; set; }

    [Required, MaxLength(50)]
    public string PolicyPrefix { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string NetworkCategory { get; set; } = "Both"; // 'Cashless', 'Reimbursement', 'Both'

    public bool AuthorizationRequired { get; set; } = true;

    [MaxLength(150)]
    public string? ContactPerson { get; set; }

    [MaxLength(20)]
    public string? ContactNumber { get; set; }

    [MaxLength(150)]
    public string? Email { get; set; }

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation property
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }
}
