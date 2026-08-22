using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class CorporateListItemViewModel
{
    public int Corporate_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string? Corporate_Code { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string Corporate_Type { get; set; } = string.Empty;
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public decimal? Credit_Limit { get; set; }
    public int? Credit_Days { get; set; }
    public string BillingCycle { get; set; } = string.Empty;
    public string Contact_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public int RatesCount { get; set; }
    public List<CorporateHospitalRateListItemViewModel> Rates { get; set; } = [];
}

public class CorporateIndexViewModel
{
    public List<CorporateListItemViewModel> Corporates { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public string? SelectedType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> TypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
}

public class CorporateFormViewModel
{
    public int Corporate_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Display(Name = "Corporate Code")]
    [MaxLength(50)]
    public string? Corporate_Code { get; set; }

    [Required(ErrorMessage = "Corporate Name is mandatory.")]
    [StringLength(200, ErrorMessage = "Corporate Name cannot exceed 200 characters.")]
    [Display(Name = "Corporate Name")]
    public string Corporate_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Type is mandatory.")]
    [Display(Name = "Corporate Type")]
    public string Corporate_Type { get; set; } = "ALL";

    [Required(ErrorMessage = "Effective From date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [Required(ErrorMessage = "Effective To date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime Effective_To { get; set; } = DateTime.Today.AddYears(1);

    [Range(0, 999999999.99, ErrorMessage = "Credit Limit must be a valid positive amount.")]
    [Display(Name = "Credit Limit (₹)")]
    public decimal? Credit_Limit { get; set; }

    [Range(0, 3650, ErrorMessage = "Credit Days must be a positive number of days.")]
    [Display(Name = "Credit Days")]
    public int? Credit_Days { get; set; }

    [Required(ErrorMessage = "Billing Cycle is mandatory.")]
    [Display(Name = "Billing Cycle")]
    public string BillingCycle { get; set; } = "Monthly";

    [Required(ErrorMessage = "Contact Number is mandatory.")]
    [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Please enter a valid 10-digit mobile number (e.g. 9876543210).")]
    [Display(Name = "Contact Number")]
    public string Contact_No { get; set; } = string.Empty;

    [EmailAddress(ErrorMessage = "Please enter a valid email address.")]
    [MaxLength(150)]
    [Display(Name = "Email Address")]
    public string? Email { get; set; }

    [MaxLength(500)]
    [Display(Name = "Address")]
    public string? Address { get; set; }

    [RegularExpression(@"^[1-9][0-9]{5}$", ErrorMessage = "Please enter a valid 6-digit Pincode.")]
    [MaxLength(20)]
    [Display(Name = "Pincode")]
    public string? Pincode { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown helpers
    public List<SelectListItem> CorporateTypeOptions { get; set; } = [];
    public List<SelectListItem> BillingCycleOptions { get; set; } = [];
}
