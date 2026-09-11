using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("LanguageMaster")]
public class LanguageMaster
{
    [Key]
    public int    LanguageId   { get; set; }
    public string LanguageName { get; set; } = string.Empty;
    public bool   IsActive     { get; set; } = true;
    public DateTime CreatedDate { get; set; } = DateTime.Now;
}
