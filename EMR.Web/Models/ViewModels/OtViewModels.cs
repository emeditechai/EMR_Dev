using System.ComponentModel.DataAnnotations;
using EMR.Web.Models.Entities;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class OtListItemViewModel
{
    public int OtId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string? FloorCode { get; set; }
    public int? BuildingId { get; set; }
    public string? BuildingName { get; set; }
    public string? BuildingCode { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string Capacity { get; set; } = string.Empty;
    public bool EmergencyAvailable { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }

    public string LocationFormatted => string.IsNullOrWhiteSpace(BuildingName)
        ? $"{FloorName}"
        : $"{BuildingName} — {FloorName}";
}

public class OtFormViewModel
{
    public int OtId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Floor is required")]
    [Display(Name = "Floor / Location")]
    public int FloorId { get; set; }

    [Required(ErrorMessage = "OT Code is required")]
    [StringLength(50, ErrorMessage = "OT Code cannot exceed 50 characters")]
    [Display(Name = "OT Code")]
    public string OtCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "OT Name is required")]
    [StringLength(200, ErrorMessage = "OT Name cannot exceed 200 characters")]
    [Display(Name = "OT Name")]
    public string OtName { get; set; } = string.Empty;

    [Required(ErrorMessage = "OT Type is required")]
    [StringLength(100, ErrorMessage = "OT Type cannot exceed 100 characters")]
    [Display(Name = "OT Type")]
    public string OtType { get; set; } = string.Empty;

    [Required(ErrorMessage = "Capacity is required")]
    [StringLength(100, ErrorMessage = "Capacity cannot exceed 100 characters")]
    [Display(Name = "Capacity / Tables")]
    public string Capacity { get; set; } = "1 Table";

    [Display(Name = "24x7 Emergency Available")]
    public bool EmergencyAvailable { get; set; } = false;

    [StringLength(500)]
    [Display(Name = "Description / Special Features")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dropdown options
    public List<SelectListItem> FloorOptions { get; set; } = [];
    public List<SelectListItem> OtTypeOptions { get; set; } = [];
}

public class OtDetailsViewModel
{
    public OtMaster Ot { get; set; } = null!;
    public List<OtEquipmentMaster> Equipments { get; set; } = [];
    public List<OtTariffMaster> Tariffs { get; set; } = [];

    public bool HasConfiguredTariffs => Tariffs.Count > 0;
    public bool HasEquipments => Equipments.Count > 0;
}
