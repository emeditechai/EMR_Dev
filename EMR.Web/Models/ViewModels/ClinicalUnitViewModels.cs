using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class ClinicalUnitListItemViewModel
{
    public int UnitId { get; set; }
    public string UnitCode { get; set; } = string.Empty;
    public string UnitName { get; set; } = string.Empty;
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public int? ConsultantInChargeDoctorId { get; set; }
    public string? ConsultantName { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class ClinicalUnitFormViewModel
{
    public int UnitId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Please select a Department.")]
    [Display(Name = "Department")]
    public int? DepartmentId { get; set; }

    [Required(ErrorMessage = "Please select a Speciality.")]
    [Display(Name = "Speciality")]
    public int? SpecialityId { get; set; }

    [Required(ErrorMessage = "Unit Code is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Only letters, numbers, hyphens, and underscores are allowed.")]
    [Display(Name = "Unit Code")]
    public string UnitCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Unit Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Unit Name")]
    public string UnitName { get; set; } = string.Empty;

    [Display(Name = "Consultant-in-Charge")]
    public int? ConsultantInChargeDoctorId { get; set; }

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> DepartmentOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> SpecialityOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> DoctorOptions { get; set; } = new List<SelectListItem>();
}

public class ClinicalUnitDetailsViewModel
{
    public int UnitId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public string? DepartmentType { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public string UnitCode { get; set; } = string.Empty;
    public string UnitName { get; set; } = string.Empty;
    public int? ConsultantInChargeDoctorId { get; set; }
    public string? ConsultantName { get; set; }
    public string? ConsultantPhoneNumber { get; set; }
    public string? ConsultantEmail { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}

public class DoctorOptionDto
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int PrimarySpecialityId { get; set; }
    public string? SpecialityName { get; set; }
}
