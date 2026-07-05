using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrTemplateFields", Schema = "dbo")]
public class EmrTemplateField
{
    [Key]
    public int FieldId { get; set; }

    public int SectionId { get; set; }

    [Required, MaxLength(100)]
    public string FieldName { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string FieldType { get; set; } = "Text"; // Text, TextArea, Select, MultiSelect, Number, Checkbox, Date, ImageUpload, Paint, FileUpload, RichText

    public string? OptionsJson { get; set; } // JSON array of choices for Select/MultiSelect

    public bool IsRequired { get; set; } = false;
    public int DisplayOrder { get; set; } = 0;
    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;

    [ForeignKey("SectionId")]
    public EmrTemplateSection? Section { get; set; }
}
