using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class CorporateHospitalRateListItemViewModel
{
    public int CorpRate_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int Corporate_ID { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string? Corporate_Code { get; set; }
    public string RateServiceType { get; set; } = string.Empty; // Room, Procedure, OT, ICU, HospitalService, Package
    public int ReferenceMaster_ID { get; set; }
    public string RateType { get; set; } = "Percentage"; // Percentage, Rate, Both
    public decimal? Rate { get; set; }
    public decimal? DiscountPercent { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Resolved dynamic master values
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }
    public decimal StandardBaseRate { get; set; }
}

public class CorporateHospitalRateFormViewModel
{
    public int CorpRate_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Corporate Partner is mandatory.")]
    [Display(Name = "Corporate Partner")]
    public int Corporate_ID { get; set; }

    public string? Corporate_Name { get; set; }

    [Required(ErrorMessage = "Rate Service Type is mandatory.")]
    [Display(Name = "Rate Service Type")]
    public string RateServiceType { get; set; } = "Procedure"; // Room, Procedure, OT, ICU, HospitalService, Package

    [Required(ErrorMessage = "Reference Master Service Item is mandatory.")]
    [Display(Name = "Master Service Item")]
    public int ReferenceMaster_ID { get; set; }

    [Required(ErrorMessage = "Rate Type is mandatory.")]
    [Display(Name = "Rate Type")]
    public string RateType { get; set; } = "Percentage"; // Percentage, Rate, Both

    [Range(0, 999999999.99, ErrorMessage = "Rate must be a positive amount.")]
    [Display(Name = "Contracted Rate (₹)")]
    public decimal? Rate { get; set; }

    [Range(0, 100.00, ErrorMessage = "Discount percentage must be between 0 and 100%.")]
    [Display(Name = "Discount Percent (%)")]
    public decimal? DiscountPercent { get; set; }

    [Required(ErrorMessage = "Effective From date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [Required(ErrorMessage = "Effective To date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime Effective_To { get; set; } = DateTime.Today.AddYears(1);

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown helpers
    public List<SelectListItem> RateServiceTypeOptions { get; set; } = [];
    public List<SelectListItem> RateTypeOptions { get; set; } = [];
    public List<SelectListItem> MasterItemOptions { get; set; } = [];
}

public class MasterServiceItemViewModel
{
    public string RateServiceType { get; set; } = string.Empty;
    public int ReferenceMaster_ID { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal BaseRate { get; set; }
}

public class CorporateRatesModalViewModel
{
    public int Corporate_ID { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string? Corporate_Code { get; set; }
    public string? Corporate_Type { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public List<CorporateHospitalRateListItemViewModel> Rates { get; set; } = [];
}
