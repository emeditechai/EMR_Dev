using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabFranchiseIndexViewModel
{
    public List<LabFranchiseModel> Franchises { get; set; } = [];
    public int? SelectedFranchiseType { get; set; }
    public int? SelectedParentBranchId { get; set; }
    public bool? SelectedStatus { get; set; }
    public bool? SelectedIsActive { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> FranchiseTypeOptions { get; set; } = [];
    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public List<SelectListItem> IsActiveOptions { get; set; } = [];
}

public class LabFranchiseWizardViewModel
{
    // === Tab 1: Basic Details ===
    public int Franchise_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Franchise Code")]
    public string? Franchise_Code { get; set; } // Readonly, auto-generated

    [Required(ErrorMessage = "Franchise Name is required.")]
    [StringLength(100, ErrorMessage = "Franchise Name cannot exceed 100 characters.")]
    [Display(Name = "Franchise Name")]
    public string Franchise_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Mobile Number is required.")]
    [RegularExpression(@"^[0-9]{10}$", ErrorMessage = "Please enter a valid 10-digit mobile number.")]
    [Display(Name = "Mobile Number")]
    public string Mobile_No { get; set; } = string.Empty;

    [EmailAddress(ErrorMessage = "Please enter a valid email address.")]
    [StringLength(200, ErrorMessage = "Email cannot exceed 200 characters.")]
    [Display(Name = "Email Address")]
    public string? Email { get; set; }

    [Required(ErrorMessage = "Franchise Type is required.")]
    [Display(Name = "Franchise Type")]
    public int Franchise_Type { get; set; } = 1; // 1 = Collection Center, 2 = Franchise Lab, 3 = Pickup Point, 4 = Marketing

    [Required(ErrorMessage = "Parent Branch is required.")]
    [Display(Name = "Parent Branch")]
    public int Parent_Branch_ID { get; set; }

    [Display(Name = "Onboarding Date")]
    [DataType(DataType.Date)]
    public DateTime? Onboarding_Date { get; set; }

    [Display(Name = "Go Live Date")]
    [DataType(DataType.Date)]
    public DateTime? Go_Live_Date { get; set; }

    [Display(Name = "Agreement Document")]
    public IFormFile? Agreement_Doc_File { get; set; }

    public string? Agreement_Doc_Path { get; set; }

    [Display(Name = "Agreement Valid From")]
    [DataType(DataType.Date)]
    public DateTime? Agreement_Valid_From { get; set; }

    [Display(Name = "Agreement Valid To")]
    [DataType(DataType.Date)]
    public DateTime? Agreement_Valid_To { get; set; }

    [Display(Name = "Is Suspended")]
    public bool Status { get; set; } = false; // Default NO (0)

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true; // Default 1 (Toggle button)

    // === Tab 2: Credit Limit ===
    public int Credit_ID { get; set; }

    [Required(ErrorMessage = "Credit Facility Type is required.")]
    [Display(Name = "Credit Facility Type")]
    public int Credit_Facility_Type { get; set; } = 1; // 1 = Prepaid (Wallet), 2 = Postpaid (Credit), 3 = Hybrid

    [Required(ErrorMessage = "Credit Limit is required.")]
    [Range(0, 99999999, ErrorMessage = "Credit Limit must be a valid non-negative number.")]
    [Display(Name = "Credit Limit")]
    public decimal Credit_Limit { get; set; } = 0;

    [Display(Name = "Credit Days")]
    [Range(0, 365, ErrorMessage = "Credit Days must be between 0 and 365.")]
    public int? Credit_Days { get; set; }

    [Required(ErrorMessage = "Grace Days is required.")]
    [Range(0, 365, ErrorMessage = "Grace Days must be a valid non-negative number.")]
    [Display(Name = "Grace Days")]
    public int Grace_Days { get; set; } = 0;

    [Range(0, 99999999, ErrorMessage = "Security Deposit Amount must be a valid non-negative number.")]
    [Display(Name = "Security Deposit Amount")]
    public decimal? Security_Deposit_Amount { get; set; }

    [Display(Name = "Security Deposit Received On")]
    [DataType(DataType.Date)]
    public DateTime? Security_Deposit_Received_On { get; set; }

    [Range(0, 100, ErrorMessage = "Interest rate percentage must be between 0 and 100.")]
    [Display(Name = "Interest On Overdue (%)")]
    public decimal? Interest_On_Overdue_Percent { get; set; }

    [Range(0, 99999999, ErrorMessage = "Temporary Limit Increase must be a non-negative number.")]
    [Display(Name = "Temporary Limit Increase")]
    public decimal Temporary_Limit_Increase { get; set; } = 0;

    [Display(Name = "Temp Limit Valid Till")]
    [DataType(DataType.Date)]
    public DateTime? Temp_Limit_Valid_Till { get; set; }

    // Dropdown Select Lists
    public List<SelectListItem> FranchiseTypeOptions { get; set; } = [];
    public List<SelectListItem> ParentBranchOptions { get; set; } = [];
    public List<SelectListItem> CreditFacilityTypeOptions { get; set; } = [];
}
