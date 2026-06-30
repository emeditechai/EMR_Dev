using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

public class EmailTemplate
{
    [Key]
    public int Id { get; set; }

    public int BranchId { get; set; }

    [Required]
    [MaxLength(100)]
    public string TemplateName { get; set; } = string.Empty;

    [Required]
    [MaxLength(255)]
    public string Subject { get; set; } = string.Empty;

    [Required]
    public string HtmlBody { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;

    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
