using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class DoctorMaster
{
    public int DoctorId { get; set; }

    [Required, MaxLength(150)]
    public string FullName { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string Gender { get; set; } = string.Empty;

    public DateTime? DateOfBirth { get; set; }

    [Required, MaxLength(150)]
    public string EmailId { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string PhoneNumber { get; set; } = string.Empty;

    [MaxLength(80)]
    public string? MedicalLicenseNo { get; set; }

    public int PrimarySpecialityId { get; set; }
    public int? SecondarySpecialityId { get; set; }
    public DateTime? JoiningDate { get; set; }

    public bool IsActive { get; set; } = true;
    public int CreatedBranchId { get; set; }

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
