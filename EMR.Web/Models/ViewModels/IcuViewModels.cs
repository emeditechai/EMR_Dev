using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class IcuListItemViewModel
{
    public int IcuId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public int? FloorId { get; set; }
    public string? FloorName { get; set; }
    public string? FloorCode { get; set; }
    public string? BuildingName { get; set; }
    public string IcuCode { get; set; } = string.Empty;
    public string IcuName { get; set; } = string.Empty;
    public string IcuType { get; set; } = string.Empty;
    public int BedCapacity { get; set; }
    public int VentilatorCapacity { get; set; }
    public int IsolationCapacity { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int ActiveTariffsCount { get; set; }
    public int TotalTariffsCount { get; set; }
}

public class IcuConfigurationFormViewModel
{
    public int IcuId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Ward / Location is required")]
    [Display(Name = "IPD Ward / Location")]
    public int WardId { get; set; }

    [Required(ErrorMessage = "ICU Code is required")]
    [StringLength(50, ErrorMessage = "ICU Code cannot exceed 50 characters")]
    [Display(Name = "ICU Code")]
    public string IcuCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "ICU Name is required")]
    [StringLength(100, ErrorMessage = "ICU Name cannot exceed 100 characters")]
    [Display(Name = "ICU Name / Description")]
    public string IcuName { get; set; } = string.Empty;

    [Required(ErrorMessage = "ICU Type is required")]
    [StringLength(50)]
    [Display(Name = "Critical Care / ICU Type")]
    public string IcuType { get; set; } = "ICU"; // ICU, HDU, NICU, PICU, CCU, etc.

    [Required(ErrorMessage = "Bed Capacity is required")]
    [Range(1, 500, ErrorMessage = "Bed Capacity must be between 1 and 500")]
    [Display(Name = "Total Bed Capacity")]
    public int BedCapacity { get; set; } = 1;

    [Range(0, 500, ErrorMessage = "Ventilator Capacity must be 0 or more")]
    [Display(Name = "Ventilator Equipped Beds")]
    public int VentilatorCapacity { get; set; } = 0;

    [Range(0, 500, ErrorMessage = "Isolation Capacity must be 0 or more")]
    [Display(Name = "Isolation Negative-Pressure Beds")]
    public int IsolationCapacity { get; set; } = 0;

    [StringLength(500)]
    [Display(Name = "Clinical Notes / Scope")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dropdowns
    public List<SelectListItem> WardOptions { get; set; } = [];
    public List<SelectListItem> IcuTypeOptions { get; set; } = [];
}

public class IcuTariffListItemViewModel
{
    public int IcuTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int IcuId { get; set; }
    public string IcuCode { get; set; } = string.Empty;
    public string IcuName { get; set; } = string.Empty;
    public string IcuType { get; set; } = string.Empty;
    public string? WardName { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? PatientCategory { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int TotalRateHeadsCount { get; set; }
    public string? RateHeadsSummary { get; set; }
}

public class IcuTariffDetailFormViewModel
{
    public int IcuTariffDetailId { get; set; }
    public int IcuTariffId { get; set; }

    [Required(ErrorMessage = "Rate Head Name is required")]
    [StringLength(100)]
    [Display(Name = "Rate Head / Component Name")]
    public string RateHeadName { get; set; } = string.Empty;

    [StringLength(50)]
    public string? RateHeadCode { get; set; }

    [Required(ErrorMessage = "Amount is required")]
    [Range(0, 10000000, ErrorMessage = "Amount must be a valid positive number")]
    [Display(Name = "Rate / Charge Amount")]
    public decimal RateAmount { get; set; } = 0;

    [Required]
    [StringLength(50)]
    [Display(Name = "Billing Frequency")]
    public string BillingFrequency { get; set; } = "Per Day"; // Per Day, Per Hour, Per Usage, Fixed

    public bool IsMandatory { get; set; } = true;

    [StringLength(200)]
    public string? Remarks { get; set; }

    public int DisplayOrder { get; set; } = 0;
}

public class IcuTariffFormViewModel
{
    public int IcuTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "ICU Configuration is required")]
    [Display(Name = "Intensive Care Unit (ICU)")]
    public int IcuId { get; set; }

    [Required(ErrorMessage = "Tariff Category is required")]
    [Display(Name = "Tariff / Billing Category")]
    public int TariffCategoryId { get; set; }

    [Display(Name = "Total Package Rate")]
    public decimal TotalRate { get; set; }

    [Required(ErrorMessage = "Effective From date is required")]
    [Display(Name = "Effective From")]
    [DataType(DataType.Date)]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [Display(Name = "Effective To")]
    [DataType(DataType.Date)]
    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    [Display(Name = "Package Description / Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dynamic Line Items
    public List<IcuTariffDetailFormViewModel> Details { get; set; } = [];

    // Dropdowns
    public List<SelectListItem> IcuOptions { get; set; } = [];
    public List<SelectListItem> TariffCategoryOptions { get; set; } = [];
}

public class IcuUnifiedViewModel
{
    public List<IcuListItemViewModel> Icus { get; set; } = [];
    public List<IcuTariffListItemViewModel> Tariffs { get; set; } = [];

    public int? SelectedWardId { get; set; }
    public string? SelectedIcuType { get; set; }
    public int? SelectedTariffCategoryId { get; set; }
    public int? SelectedIcuId { get; set; }
    public string ActiveTab { get; set; } = "icus"; // "icus" or "tariffs"

    public List<SelectListItem> WardOptions { get; set; } = [];
    public List<SelectListItem> IcuTypeOptions { get; set; } = [];
    public List<SelectListItem> TariffCategoryOptions { get; set; } = [];
    public List<SelectListItem> IcuOptions { get; set; } = [];

    // KPI Summary
    public int TotalIcusCount => Icus.Count;
    public int ActiveIcusCount => Icus.Count(i => i.IsActive);
    public int TotalBedCapacity => Icus.Sum(i => i.BedCapacity);
    public int TotalVentilatorCapacity => Icus.Sum(i => i.VentilatorCapacity);
    public int TotalTariffsCount => Tariffs.Count;
    public int ActiveTariffsCount => Tariffs.Count(t => t.IsActive);
}
