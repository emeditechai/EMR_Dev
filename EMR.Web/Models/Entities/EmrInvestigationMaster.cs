using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrInvestigationMaster", Schema = "dbo")]
public class EmrInvestigationMaster
{
    [Key]
    public int InvestigationId { get; set; }

    [Required, MaxLength(200)]
    public string InvestigationName { get; set; } = string.Empty;

    [MaxLength(100)]
    public string? Category { get; set; }

    [MaxLength(50)]
    public string? Unit { get; set; }

    [MaxLength(100)]
    public string? NormalRange { get; set; }

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int CreatedBy { get; set; } = 0;
    public DateTime? ModifiedDate { get; set; }
    public int? ModifiedBy { get; set; }
}
