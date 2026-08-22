using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ConsentMaster", Schema = "dbo")]
public class ConsentMaster
{
    [Key]
    public int Consent_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int Branch_ID { get; set; }

    [ForeignKey(nameof(Branch_ID))]
    public virtual BranchMaster? Branch { get; set; }

    [Required]
    [MaxLength(100)]
    public string ConsentType { get; set; } = string.Empty;

    [Required]
    [MaxLength(20)]
    public string Type { get; set; } = "IPD"; // IPD, OPD, LAB, MED

    public int? Procedure_ID { get; set; }

    [ForeignKey(nameof(Procedure_ID))]
    public virtual ProcedureMaster? Procedure { get; set; }

    [Required]
    [MaxLength(50)]
    public string Language { get; set; } = "English";

    [Required]
    public string ConsentTemplateContent { get; set; } = string.Empty;

    [Required]
    [MaxLength(20)]
    public string Version { get; set; } = "1.0";

    [Required]
    [MaxLength(50)]
    public string ValidityPeriod { get; set; } = "Per Admission";

    public bool WitnessRequired { get; set; } = true;

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? ModifiedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }
}
