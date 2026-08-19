using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("BedCategoryMaster", Schema = "dbo")]
public class BedCategoryMaster
{
    [Key]
    public int BedCategoryId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [MaxLength(50)]
    public string? CategoryCode { get; set; }

    [Required, MaxLength(150)]
    public string CategoryName { get; set; } = string.Empty;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
