using System.ComponentModel.DataAnnotations;
using EMR.Web.Models.Entities;

namespace EMR.Web.Models.ViewModels;

public class BuildingListItemViewModel
{
    public int BuildingId { get; set; }
    public string BuildingCode { get; set; } = string.Empty;
    public string BuildingName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int NumberOfFloors { get; set; }
    public int TotalFloorsConfigured { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BuildingFormViewModel
{
    public int BuildingId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Building Code is required.")]
    [StringLength(4, MinimumLength = 4, ErrorMessage = "Building Code must be exactly 4 characters (e.g. BLD1, MAIN).")]
    [RegularExpression(@"^[A-Za-z0-9]+$", ErrorMessage = "Building Code must contain only alphanumeric characters.")]
    [Display(Name = "Building Code (4 Digits/Chars)")]
    public string BuildingCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Building Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Building Name")]
    public string BuildingName { get; set; } = string.Empty;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Required(ErrorMessage = "Number of Floors is required.")]
    [Range(1, 200, ErrorMessage = "Number of floors must be between 1 and 200.")]
    [Display(Name = "Number of Floors")]
    public int NumberOfFloors { get; set; } = 1;

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}

public class BuildingDetailsViewModel
{
    public int BuildingId { get; set; }
    public string BuildingCode { get; set; } = string.Empty;
    public string BuildingName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int NumberOfFloors { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }

    public List<FloorMaster> Floors { get; set; } = new();
}
