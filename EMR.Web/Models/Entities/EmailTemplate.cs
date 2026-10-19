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

    /// <summary>The design made in the Email Templates designer (SQLScripts/2298); HtmlBody is built from it.
    /// Null for a template kept as hand-written HTML.</summary>
    public string? DesignJson { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;

    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
