using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class UserListItemViewModel
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string EmployeeCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public bool IsNursingStaff { get; set; }
    public bool IsPhlebotomist { get; set; }
    public bool IsPathologist { get; set; }
    public bool IsLabTechnician { get; set; }
    public string Branches { get; set; } = string.Empty;
    public string DepartmentNames { get; set; } = string.Empty;
}

public class UserFormViewModel
{
    public int Id { get; set; }

    [MaxLength(50)]
    [Display(Name = "Employee Code")]
    public string? EmployeeCode { get; set; }

    [Required]
    [MaxLength(100)]
    public string Username { get; set; } = string.Empty;

    [EmailAddress]
    [MaxLength(200)]
    public string? Email { get; set; }

    [Display(Name = "Password")]
    [DataType(DataType.Password)]
    public string? Password { get; set; }

    [Display(Name = "Confirm Password")]
    [DataType(DataType.Password)]
    [Compare(nameof(Password), ErrorMessage = "Passwords do not match.")]
    public string? ConfirmPassword { get; set; }

    [Required]
    [MaxLength(100)]
    [Display(Name = "First Name")]
    public string FirstName { get; set; } = string.Empty;

    [Required]
    [MaxLength(100)]
    [Display(Name = "Last Name")]
    public string LastName { get; set; } = string.Empty;

    [Phone]
    [Display(Name = "Phone Number")]
    public string? PhoneNumber { get; set; }

    [Display(Name = "Profile Picture")]
    public IFormFile? ProfilePictureFile { get; set; }

    public string? ExistingProfilePicturePath { get; set; }

    public bool IsActive { get; set; } = true;

    [Display(Name = "Is Nursing Staff")]
    public bool IsNursingStaff { get; set; }

    [Display(Name = "Is Phlebotomist")]
    public bool IsPhlebotomist { get; set; }

    [Display(Name = "Is Pathologist")]
    public bool IsPathologist { get; set; }

    [Display(Name = "Is Lab Technician")]
    public bool IsLabTechnician { get; set; }

    [DataType(DataType.Date)]
    [Display(Name = "Date of Joining")]
    public DateTime? DateOfJoining { get; set; }

    [DataType(DataType.Date)]
    [Display(Name = "Date of Birth")]
    public DateTime? DateOfBirth { get; set; }

    [MaxLength(500)]
    [Display(Name = "Address")]
    public string? Address { get; set; }

    [MaxLength(20)]
    [Display(Name = "Pincode")]
    public string? Pincode { get; set; }

    [Display(Name = "Country")]
    public int? CountryId { get; set; }

    [Display(Name = "State")]
    public int? StateId { get; set; }

    [Display(Name = "City")]
    public int? CityId { get; set; }

    [MaxLength(100)]
    [Display(Name = "Certification No")]
    public string? CertificationNo { get; set; }

    [MaxLength(100)]
    [Display(Name = "Registration No")]
    public string? RegistrationNo { get; set; }

    [Display(Name = "Shift Slot")]
    public int? ShiftSlotId { get; set; }

    [Display(Name = "Assigned Zone")]
    public int? AssignedZoneId { get; set; }

    [Display(Name = "Daily Collection Target")]
    [Range(0, 999999999.99, ErrorMessage = "Daily collection target must be a positive value.")]
    public decimal? DailyCollectionTarget { get; set; }

    [Display(Name = "Lab Shift")]
    public int? LabTechnicianShiftSlotId { get; set; }

    [MaxLength(250)]
    [Display(Name = "Analyzer Trained On")]
    public string? AnalyzerTrainedOn { get; set; }

    public List<SelectListItem> CountryOptions { get; set; } = new();
    public List<SelectListItem> StateOptions { get; set; } = new();
    public List<SelectListItem> CityOptions { get; set; } = new();
    public List<SelectListItem> ShiftSlotOptions { get; set; } = new();
    public List<SelectListItem> AssignedZoneOptions { get; set; } = new();
    public List<SelectListItem> LabShiftSlotOptions { get; set; } = new();
    public List<SelectListItem> LabAnalyzerOptions { get; set; } = new();

    public List<int> SelectedBranchIds { get; set; } = new();
    public List<int> SelectedRoleIds { get; set; } = new();
    public List<int> SelectedDepartmentIds { get; set; } = new();

    public List<SelectListItem> BranchOptions { get; set; } = new();
    public List<SelectListItem> DepartmentOptions { get; set; } = new();
    public List<BranchRoleGroup> BranchRoleGroups { get; set; } = new();
}

public class BranchRoleGroup
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public List<RoleItem> Roles { get; set; } = new();
}

public class RoleItem
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class UserDetailsViewModel
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string EmployeeCode { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string FirstName { get; set; } = string.Empty;
    public string LastName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public DateTime? DateOfJoining { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public string? CountryName { get; set; }
    public string? StateName { get; set; }
    public string? CityName { get; set; }
    public bool IsActive { get; set; }
    public bool IsNursingStaff { get; set; }
    public bool IsPhlebotomist { get; set; }
    public bool IsPathologist { get; set; }
    public bool IsLabTechnician { get; set; }

    public string? CertificationNo { get; set; }
    public string? RegistrationNo { get; set; }
    public int? ShiftSlotId { get; set; }
    public string? ShiftSlotName { get; set; }
    public int? AssignedZoneId { get; set; }
    public string? AssignedZoneName { get; set; }
    public decimal? DailyCollectionTarget { get; set; }

    public int? LabTechnicianShiftSlotId { get; set; }
    public string? LabTechnicianShiftSlotName { get; set; }
    public string? AnalyzerTrainedOn { get; set; }

    public bool IsLockedOut { get; set; }
    public DateTime? LastLoginDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? LastModifiedDate { get; set; }
    public string? ProfilePicturePath { get; set; }
    public List<string> Branches { get; set; } = new();
    public List<string> DepartmentNames { get; set; } = new();
    public List<BranchRoleDetailItem> BranchRoleMappings { get; set; } = new();
}

public class BranchRoleDetailItem
{
    public string BranchName { get; set; } = string.Empty;
    public string? EmployeeCode { get; set; }
    public List<string> Roles { get; set; } = new();
}
