using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class NursingStationListItemViewModel
{
    public int NursingStationId { get; set; }
    public string StationCode { get; set; } = string.Empty;
    public string StationName { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string? FloorName { get; set; }
    public string? ResponsibleNurse { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class NursingStationFormViewModel
{
    public int NursingStationId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Please select a Ward.")]
    [Display(Name = "Parent Ward")]
    public int? WardId { get; set; }

    [Required(ErrorMessage = "Station Code is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Only letters, numbers, hyphens, and underscores are allowed.")]
    [Display(Name = "Station Code")]
    public string StationCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Station Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Station Name")]
    public string StationName { get; set; } = string.Empty;

    [Display(Name = "Responsible In-Charge Nurse")]
    public string? ResponsibleNurse { get; set; }

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Desk Location")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> WardOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> NurseOptions { get; set; } = new List<SelectListItem>();
}

public class NursingStationDetailsViewModel
{
    public int NursingStationId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string? FloorName { get; set; }
    public string? BuildingName { get; set; }
    public string StationCode { get; set; } = string.Empty;
    public string StationName { get; set; } = string.Empty;
    public string? ResponsibleNurse { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}
