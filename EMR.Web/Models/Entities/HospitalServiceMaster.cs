using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HospitalServiceMaster", Schema = "dbo")]
public class HospitalServiceMaster
{
    [Key]
    public int HospitalServiceId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    public int BranchId { get; set; }

    [Required]
    public int DepartmentId { get; set; }

    [Required, MaxLength(50)]
    public string ServiceCode { get; set; } = string.Empty;

    [Required, MaxLength(200)]
    public string ServiceName { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string ServiceType { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string UOM { get; set; } = string.Empty;

    [Column(TypeName = "decimal(5,2)")]
    public decimal TaxPercentage { get; set; } = 0;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation / Display helpers
    [ForeignKey(nameof(BranchId))]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey(nameof(DepartmentId))]
    public virtual DepartmentMaster? Department { get; set; }
}
