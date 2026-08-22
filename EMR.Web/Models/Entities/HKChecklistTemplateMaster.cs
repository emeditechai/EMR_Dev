using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HKChecklistTemplateMaster", Schema = "dbo")]
public class HKChecklistTemplateMaster
{
    [Key]
    public int Template_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(50)]
    public string TemplateCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string TemplateName { get; set; } = string.Empty;

    public string? ChecklistItemsJSON { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }
}
