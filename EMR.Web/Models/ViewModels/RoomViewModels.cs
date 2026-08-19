using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class RoomListItemViewModel
{
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string FloorCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string RoomType { get; set; } = string.Empty;
    public string RoomCategory { get; set; } = string.Empty;
    public bool IsIsolation { get; set; }
    public int BedCapacity { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class RoomFormViewModel
{
    public int RoomId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Building is required.")]
    [Display(Name = "Building")]
    public int? BuildingId { get; set; }

    [Required(ErrorMessage = "Floor is required.")]
    [Display(Name = "Floor")]
    public int? FloorId { get; set; }

    [Required(ErrorMessage = "Ward is required.")]
    [Display(Name = "Parent Ward")]
    public int? WardId { get; set; }

    [Required(ErrorMessage = "Room Number is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [Display(Name = "Room Number")]
    public string RoomNumber { get; set; } = string.Empty;

    [Required(ErrorMessage = "Room Type is required.")]
    [MaxLength(50)]
    [Display(Name = "Room Type")]
    public string RoomType { get; set; } = "Single Room";

    [Required(ErrorMessage = "Room Category is required.")]
    [MaxLength(50)]
    [Display(Name = "Room Category")]
    public string RoomCategory { get; set; } = "General";

    [Display(Name = "Isolation Room")]
    public bool IsIsolation { get; set; } = false;

    [Required(ErrorMessage = "Bed Capacity is required.")]
    [Range(1, 100, ErrorMessage = "Bed Capacity must be between 1 and 100.")]
    [Display(Name = "Bed Capacity")]
    public int BedCapacity { get; set; } = 1;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Amenities")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> BuildingOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> FloorOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> WardOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> RoomTypeOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> RoomCategoryOptions { get; set; } = new List<SelectListItem>();
}

public class RoomDetailsViewModel
{
    public int RoomId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string FloorCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string RoomType { get; set; } = string.Empty;
    public string RoomCategory { get; set; } = string.Empty;
    public bool IsIsolation { get; set; }
    public int BedCapacity { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}

public class FloorOptionDto
{
    public int FloorId { get; set; }
    public string FloorCode { get; set; } = string.Empty;
    public string FloorName { get; set; } = string.Empty;
    public int? BuildingId { get; set; }
}

public class WardOptionDto
{
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public string WardType { get; set; } = string.Empty;
    public int FloorId { get; set; }
}
