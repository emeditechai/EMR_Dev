using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorSubSpecialityListItemViewModel
{
    public int SubSpecialityId { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class DoctorSubSpecialityFormViewModel
{
    public int SubSpecialityId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Please select a Doctor Speciality.")]
    [Display(Name = "Parent Speciality")]
    public int? SpecialityId { get; set; }

    public string? SpecialityName { get; set; }

    [Required(ErrorMessage = "Sub-Speciality Code is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Only letters, numbers, hyphens, and underscores are allowed.")]
    [Display(Name = "Sub-Speciality Code")]
    public string SubSpecialityCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Sub-Speciality Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Sub-Speciality Name")]
    public string SubSpecialityName { get; set; } = string.Empty;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public IEnumerable<SelectListItem> SpecialityOptions { get; set; } = new List<SelectListItem>();
}

public class DoctorSubSpecialityDetailsViewModel
{
    public int SubSpecialityId { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}
