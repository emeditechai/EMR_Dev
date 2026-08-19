using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorSubSpecialityMaster", Schema = "dbo")]
public class DoctorSubSpecialityMaster
{
    [Key]
    public int SubSpecialityId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int SpecialityId { get; set; }

    public string? SpecialityName { get; set; }
    public string? SpecialityCode { get; set; }

    [Required, MaxLength(50)]
    public string SubSpecialityCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string SubSpecialityName { get; set; } = string.Empty;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation
    public DoctorSpecialityMaster? Speciality { get; set; }
}
