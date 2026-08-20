using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ClinicalUnitMaster", Schema = "dbo")]
public class ClinicalUnitMaster
{
    [Key]
    public int UnitId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int DepartmentId { get; set; }

    [Required]
    public int SpecialityId { get; set; }

    [Required, MaxLength(50)]
    public string UnitCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string UnitName { get; set; } = string.Empty;

    public int? ConsultantInChargeDoctorId { get; set; }

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    [NotMapped]
    public string? DepartmentName { get; set; }
    [NotMapped]
    public string? DepartmentCode { get; set; }
    [NotMapped]
    public string? SpecialityName { get; set; }
    [NotMapped]
    public string? SpecialityCode { get; set; }
    [NotMapped]
    public string? ConsultantName { get; set; }

    // Navigations
    public DepartmentMaster? Department { get; set; }
    public DoctorSpecialityMaster? Speciality { get; set; }
    public DoctorMaster? ConsultantInCharge { get; set; }
}
