using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("AnaesthesiaTypeMaster", Schema = "dbo")]
public class AnaesthesiaTypeMaster
{
    [Key]
    public int AnaesthesiaTypeId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required]
    [StringLength(50)]
    public string TypeCode { get; set; } = string.Empty;

    [Required]
    [StringLength(100)]
    public string TypeName { get; set; } = string.Empty;

    [StringLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? ModifiedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    // Navigation properties
    [ForeignKey(nameof(BranchId))]
    public virtual BranchMaster? Branch { get; set; }

    public virtual ICollection<AnaesthesiaRateMaster> Rates { get; set; } = new List<AnaesthesiaRateMaster>();
}
