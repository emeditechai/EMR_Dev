using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class HospitalServiceRateListItemViewModel
{
    public int ServiceRateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int HospitalServiceId { get; set; }
    public string ServiceCode { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    public string ServiceType { get; set; } = string.Empty;
    public string UOM { get; set; } = string.Empty;
    public decimal TaxPercentage { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public decimal Rate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class HospitalServiceRateFormViewModel
{
    public int ServiceRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Tariff Category is required")]
    [Display(Name = "Tariff Category")]
    public int TariffCategoryId { get; set; }

    [Required(ErrorMessage = "Hospital Service is required")]
    [Display(Name = "Hospital Service")]
    public int HospitalServiceId { get; set; }

    [Required(ErrorMessage = "Rate is required")]
    [Range(0, 99999999.99, ErrorMessage = "Rate must be 0 or greater")]
    [Display(Name = "Rate (Amount)")]
    public decimal Rate { get; set; }

    [Required(ErrorMessage = "Effective From Date is required")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    [Display(Name = "Description / Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Is Active")]
    public bool IsActive { get; set; } = true;

    // Lock indicator when opened from Hospital Services Details
    public bool IsServiceLocked { get; set; }
    public string? SelectedServiceName { get; set; }

    // Dropdowns
    public List<SelectListItem> TariffCategoryOptions { get; set; } = [];
    public List<SelectListItem> HospitalServiceOptions { get; set; } = [];
}

