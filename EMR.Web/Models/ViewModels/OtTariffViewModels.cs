using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class OtTariffListItemViewModel
{
    public int OtTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int OtId { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string? FloorName { get; set; }
    public string? BuildingName { get; set; }
    public decimal OtUsageRate { get; set; }
    public decimal NursingCharges { get; set; }
    public decimal EquipmentCharges { get; set; }
    public decimal RecoveryCharges { get; set; }
    public decimal ConsumableCharges { get; set; }
    public decimal SpecialEquipmentCharges { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class OtTariffFormViewModel
{
    public int OtTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Tariff Category is required")]
    [Display(Name = "Tariff Category")]
    public int TariffCategoryId { get; set; }

    [Required(ErrorMessage = "Operation Theatre (OT) is required")]
    [Display(Name = "Operation Theatre (OT)")]
    public int OtId { get; set; }

    [Display(Name = "OT Usage Rate")]
    [Range(0, 10000000, ErrorMessage = "OT Usage Rate must be positive")]
    public decimal OtUsageRate { get; set; } = 0;

    [Display(Name = "OT Nursing Charges")]
    [Range(0, 10000000, ErrorMessage = "Nursing Charges must be positive")]
    public decimal NursingCharges { get; set; } = 0;

    [Display(Name = "Standard Equipment Charges")]
    [Range(0, 10000000, ErrorMessage = "Equipment Charges must be positive")]
    public decimal EquipmentCharges { get; set; } = 0;

    [Display(Name = "Recovery Room Charges")]
    [Range(0, 10000000, ErrorMessage = "Recovery Charges must be positive")]
    public decimal RecoveryCharges { get; set; } = 0;

    [Display(Name = "Surgical Consumables Charges")]
    [Range(0, 10000000, ErrorMessage = "Consumables Charges must be positive")]
    public decimal ConsumableCharges { get; set; } = 0;

    [Display(Name = "Special Equipment Charges (C-Arm/Laser/Microscope)")]
    [Range(0, 10000000, ErrorMessage = "Special Equipment Charges must be positive")]
    public decimal SpecialEquipmentCharges { get; set; } = 0;

    [Display(Name = "Total OT Tariff Rate")]
    public decimal TotalRate { get; set; }

    [Required(ErrorMessage = "Effective From date is required")]
    [Display(Name = "Effective From")]
    [DataType(DataType.Date)]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [Display(Name = "Effective To")]
    [DataType(DataType.Date)]
    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    [Display(Name = "Description / Package Notes")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    public bool IsOtLocked { get; set; } = false;

    // Dropdown options
    public List<SelectListItem> TariffCategoryOptions { get; set; } = [];
    public List<SelectListItem> OtOptions { get; set; } = [];
}
