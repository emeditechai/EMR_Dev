using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorFormViewModel
{
    public int DoctorId { get; set; }

    [Required(ErrorMessage = "Doctor Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Doctor Name")]
    public string FullName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Gender is required.")]
    [Display(Name = "Gender")]
    public string Gender { get; set; } = string.Empty;

    [DataType(DataType.Date)]
    [Display(Name = "Date of Birth")]
    public DateTime? DateOfBirth { get; set; }

    [Required(ErrorMessage = "Email ID is required.")]
    [EmailAddress(ErrorMessage = "Enter a valid email address.")]
    [MaxLength(150)]
    [Display(Name = "Email ID")]
    public string EmailId { get; set; } = string.Empty;

    [Required(ErrorMessage = "Phone Number is required.")]
    [RegularExpression(@"^[0-9+\-() ]{8,20}$", ErrorMessage = "Enter a valid phone number.")]
    [Display(Name = "Phone Number")]
    public string PhoneNumber { get; set; } = string.Empty;

    [MaxLength(80)]
    [Display(Name = "Medical License / MMC")]
    public string? MedicalLicenseNo { get; set; }

    [Required(ErrorMessage = "Primary Speciality is required.")]
    [Display(Name = "Speciality (Primary)")]
    public int? PrimarySpecialityId { get; set; }

    [Display(Name = "Secondary Speciality")]
    public int? SecondarySpecialityId { get; set; }

    [DataType(DataType.Date)]
    [Display(Name = "Joining Date")]
    public DateTime? JoiningDate { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public List<int> SelectedBranchIds { get; set; } = [];
    public List<int> SelectedDepartmentIds { get; set; } = [];

    public bool CanAssignMultipleBranches { get; set; }
    public int CurrentBranchId { get; set; }
    public string CurrentBranchName { get; set; } = string.Empty;

    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
}

public class DoctorListItemViewModel
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string PrimarySpecialityName { get; set; } = string.Empty;
    public string DepartmentNames { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string EmailId { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}

public class DoctorDetailsViewModel
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public DateTime? DateOfBirth { get; set; }
    public string EmailId { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string? MedicalLicenseNo { get; set; }

    public int PrimarySpecialityId { get; set; }
    public string PrimarySpecialityName { get; set; } = string.Empty;

    public int? SecondarySpecialityId { get; set; }
    public string? SecondarySpecialityName { get; set; }

    public DateTime? JoiningDate { get; set; }
    public bool IsActive { get; set; }

    public List<string> BranchNames { get; set; } = [];
    public List<string> DepartmentNames { get; set; } = [];

    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
