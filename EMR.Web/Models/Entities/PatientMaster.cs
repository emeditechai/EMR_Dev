using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class PatientMaster
{
    public int PatientId { get; set; }

    [Required, MaxLength(20)]
    public string PatientCode { get; set; } = string.Empty;

    [Required, MaxLength(15)]
    public string PhoneNumber { get; set; } = string.Empty;

    [MaxLength(15)]
    public string? SecondaryPhoneNumber { get; set; }

    [MaxLength(10)]
    public string? Salutation { get; set; }   // Mr., Mrs., Master

    [Required, MaxLength(100)]
    public string FirstName { get; set; } = string.Empty;

    [MaxLength(100)]
    public string? MiddleName { get; set; }

    [Required, MaxLength(100)]
    public string LastName { get; set; } = string.Empty;

    [Required, MaxLength(10)]
    public string Gender { get; set; } = string.Empty;

    public int? ReligionId { get; set; }

    [MaxLength(150)]
    public string? EmailId { get; set; }

    [MaxLength(200)]
    public string? GuardianName { get; set; }

    public int? CountryId { get; set; }
    public int? StateId { get; set; }
    public int? DistrictId { get; set; }
    public int? CityId { get; set; }
    public int? AreaId { get; set; }

    public int? IdentificationTypeId { get; set; }

    [MaxLength(100)]
    public string? IdentificationNumber { get; set; }

    [MaxLength(500)]
    public string? IdentificationFilePath { get; set; }

    public int? OccupationId { get; set; }
    public int? MaritalStatusId { get; set; }

    [MaxLength(10)]
    public string? BloodGroup { get; set; }

    [MaxLength(500)]
    public string? KnownAllergies { get; set; }

    [MaxLength(1000)]
    public string? Remarks { get; set; }

    public int? BranchId { get; set; }
    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
