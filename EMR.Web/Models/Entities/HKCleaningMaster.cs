using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HKCleaningMaster", Schema = "dbo")]
public class HKCleaningMaster
{
    [Key]
    public int Cleaning_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(100)]
    public string CleaningType { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string Frequency { get; set; } = string.Empty;

    [Column("ChecklistTemplate_ID")]
    public int? ChecklistTemplate_ID { get; set; }

    [Required, MaxLength(200)]
    public string ChemicalUsed { get; set; } = string.Empty;

    [Required, MaxLength(200)]
    public string EquipmentUsed { get; set; } = string.Empty;

    public int SLA_Minutes { get; set; } = 30;

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey("ChecklistTemplate_ID")]
    public virtual HKChecklistTemplateMaster? ChecklistTemplate { get; set; }
}
