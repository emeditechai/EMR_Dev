using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class OtEquipmentListItemViewModel
{
    public int EquipmentId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int OtId { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string? FloorName { get; set; }
    public string? BuildingName { get; set; }
    public string EquipmentCode { get; set; } = string.Empty;
    public string EquipmentName { get; set; } = string.Empty;
    public string? EquipmentType { get; set; }
    public string? SerialNo { get; set; }
    public bool CalibrationRequired { get; set; }
    public DateTime? LastCalibrationDate { get; set; }
    public DateTime? CalibrationDueDate { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }

    public string CalibrationStatusFormatted
    {
        get
        {
            if (!CalibrationRequired) return "Not Required";
            if (!CalibrationDueDate.HasValue) return "Required (Date not set)";
            if (CalibrationDueDate.Value.Date < DateTime.Today) return "Overdue";
            if (CalibrationDueDate.Value.Date <= DateTime.Today.AddDays(30)) return "Due Soon";
            return "Calibrated";
        }
    }
}

public class OtEquipmentFormViewModel
{
    public int EquipmentId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Operation Theatre (OT) is required")]
    [Display(Name = "Operation Theatre (OT)")]
    public int OtId { get; set; }

    [Required(ErrorMessage = "Equipment Code is required")]
    [StringLength(50, ErrorMessage = "Equipment Code cannot exceed 50 characters")]
    [Display(Name = "Equipment Code")]
    public string EquipmentCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Equipment Name is required")]
    [StringLength(200, ErrorMessage = "Equipment Name cannot exceed 200 characters")]
    [Display(Name = "Equipment Name")]
    public string EquipmentName { get; set; } = string.Empty;

    [StringLength(100)]
    [Display(Name = "Equipment Category / Type")]
    public string? EquipmentType { get; set; }

    [StringLength(100)]
    [Display(Name = "Model / Serial Number")]
    public string? SerialNo { get; set; }

    [Display(Name = "Periodic Calibration Required")]
    public bool CalibrationRequired { get; set; } = false;

    [Display(Name = "Last Calibration Date")]
    [DataType(DataType.Date)]
    public DateTime? LastCalibrationDate { get; set; }

    [Display(Name = "Next Calibration Due Date")]
    [DataType(DataType.Date)]
    public DateTime? CalibrationDueDate { get; set; }

    [StringLength(500)]
    [Display(Name = "Description / Technical Specs")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    public bool IsOtLocked { get; set; } = false;

    // Dropdown options
    public List<SelectListItem> OtOptions { get; set; } = [];
    public List<SelectListItem> EquipmentTypeOptions { get; set; } = [];
}
