using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class User
{
    public int Id { get; set; }

    [Required]
    [MaxLength(100)]
    public string Username { get; set; } = string.Empty;

    [MaxLength(200)]
    public string? Email { get; set; }

    [Required]
    public string PasswordHash { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? Salt { get; set; }

    [MaxLength(100)]
    public string? FirstName { get; set; }

    [MaxLength(100)]
    public string? LastName { get; set; }

    [MaxLength(20)]
    public string? PhoneNumber { get; set; }

    [MaxLength(20)]
    public string? Phone { get; set; }

    [MaxLength(200)]
    public string? FullName { get; set; }

    [MaxLength(300)]
    public string? ProfilePicturePath { get; set; }

    [MaxLength(100)]
    public string? Role { get; set; }

    [MaxLength(250)]
    public string? DepartmentIds { get; set; }

    public DateTime? DateOfJoining { get; set; }
    public DateTime? DateOfBirth { get; set; }

    [MaxLength(500)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? Pincode { get; set; }

    public int? CountryId { get; set; }
    public CountryMaster? Country { get; set; }

    public int? StateId { get; set; }
    public StateMaster? State { get; set; }

    public int? CityId { get; set; }
    public CityMaster? City { get; set; }

    public bool IsActive { get; set; } = true;
    public bool IsNursingStaff { get; set; }
    public bool IsPhlebotomist { get; set; }
    public bool IsPathologist { get; set; }
    public bool IsLabTechnician { get; set; }
    public bool IsLockedOut { get; set; }
    public int FailedLoginAttempts { get; set; }
    public DateTime? LastLoginDate { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public DateTime? LastModifiedDate { get; set; }
    public bool MustChangePassword { get; set; }
    public DateTime? PasswordLastChanged { get; set; }
    public bool RequiresMFA { get; set; }


    public int? CompanyId { get; set; } = 1;
    public CompanyMaster? Company { get; set; }

    public ICollection<UserBranch> UserBranches { get; set; } = new List<UserBranch>();
    public ICollection<UserRole> UserRoles { get; set; } = new List<UserRole>();
}

