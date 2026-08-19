using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class WardListItemViewModel
{
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string? BuildingName { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string WardType { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public int Capacity { get; set; }
    public bool IsIsolationWard { get; set; }
    public int TotalNursingStations { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class WardFormViewModel
{
    public int WardId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Floor is required.")]
    [Display(Name = "Floor")]
    public int? FloorId { get; set; }

    [Required(ErrorMessage = "IPD Department is required.")]
    [Display(Name = "Department (IPD)")]
    public int? DepartmentId { get; set; }

    [Required(ErrorMessage = "Ward Code is required.")]
    [MaxLength(5, ErrorMessage = "Ward Code cannot exceed 5 characters.")]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Only alphanumeric characters and hyphens allowed.")]
    [Display(Name = "Ward Code (Max 5 Digits/Chars)")]
    public string WardCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Ward Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Ward Name")]
    public string WardName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Ward Type is required.")]
    [MaxLength(50)]
    [Display(Name = "Ward Type")]
    public string WardType { get; set; } = "General Ward";

    [Required(ErrorMessage = "Gender restriction is required.")]
    [MaxLength(20)]
    [Display(Name = "Gender Suitability")]
    public string Gender { get; set; } = "Unisex / All";

    [Required(ErrorMessage = "Bed capacity is required.")]
    [Range(1, 500, ErrorMessage = "Capacity must be between 1 and 500.")]
    [Display(Name = "Bed Capacity")]
    public int Capacity { get; set; } = 10;

    [Display(Name = "Isolation Ward")]
    public bool IsIsolationWard { get; set; } = false;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Location Notes")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> FloorOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> DepartmentOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> WardTypeOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> GenderOptions { get; set; } = new List<SelectListItem>();
}

public class WardDetailsViewModel
{
    public int WardId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string FloorCode { get; set; } = string.Empty;
    public string? BuildingName { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public string WardType { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public int Capacity { get; set; }
    public bool IsIsolationWard { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
    public List<NursingStationListItemViewModel> NursingStations { get; set; } = new();
}
