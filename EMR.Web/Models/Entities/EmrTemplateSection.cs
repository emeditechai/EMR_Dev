using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrTemplateSections", Schema = "dbo")]
public class EmrTemplateSection
{
    [Key]
    public int SectionId { get; set; }

    public int TemplateId { get; set; }

    [Required, MaxLength(100)]
    public string SectionName { get; set; } = string.Empty;

    public int DisplayOrder { get; set; } = 0;
    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;

    [ForeignKey("TemplateId")]
    public EmrTemplate? Template { get; set; }
}
