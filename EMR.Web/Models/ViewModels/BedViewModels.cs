using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class BedListItemViewModel
{
    public int BedId { get; set; }
    public string BedNumber { get; set; } = string.Empty;
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public string? BedCategoryCode { get; set; }
    public string BedStatus { get; set; } = "Available";
    public bool IsIsolation { get; set; }
    public bool IsICU { get; set; }
    public bool IsVentilatorCapable { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BedFormViewModel
{
    public int BedId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Building is required.")]
    [Display(Name = "Building")]
    public int? BuildingId { get; set; }

    [Required(ErrorMessage = "Ward is required.")]
    [Display(Name = "Ward")]
    public int? WardId { get; set; }

    [Required(ErrorMessage = "IPD Room is required.")]
    [Display(Name = "IPD Room")]
    public int? RoomId { get; set; }

    [Required(ErrorMessage = "Bed Number is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [Display(Name = "Bed Number")]
    public string BedNumber { get; set; } = string.Empty;

    [Required(ErrorMessage = "Bed Category is required.")]
    [Display(Name = "Bed Category")]
    public int? BedCategoryId { get; set; }

    [Required(ErrorMessage = "Bed Status is required.")]
    [MaxLength(30)]
    [Display(Name = "Bed Status")]
    public string BedStatus { get; set; } = "Available";

    [Display(Name = "Isolation Bed")]
    public bool IsIsolation { get; set; } = false;

    [Display(Name = "ICU Critical Care Bed")]
    public bool IsICU { get; set; } = false;

    [Display(Name = "Ventilator Capable")]
    public bool IsVentilatorCapable { get; set; } = false;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Feature Notes")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> BuildingOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> WardOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> RoomOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> BedCategoryOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> BedStatusOptions { get; set; } = new List<SelectListItem>();
}

public class BedDetailsViewModel
{
    public int BedId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public string? FloorName { get; set; }
    public string BedNumber { get; set; } = string.Empty;
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public string? BedCategoryCode { get; set; }
    public string BedStatus { get; set; } = "Available";
    public bool IsIsolation { get; set; }
    public bool IsICU { get; set; }
    public bool IsVentilatorCapable { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}

public class RoomOptionByWardDto
{
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string RoomType { get; set; } = string.Empty;
    public string RoomCategory { get; set; } = string.Empty;
    public int WardId { get; set; }
}

public class WardOptionByBuildingDto
{
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public string WardType { get; set; } = string.Empty;
    public int BuildingId { get; set; }
}
