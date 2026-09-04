using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabInvestigationProfileIndexViewModel
{
    public List<LabInvestigationProfileHeaderModel> Profiles { get; set; } = [];
    public int? SelectedProfileType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> ProfileTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];

    public LabMasterDashboardViewModel? Dashboard { get; set; }
}

public class LabInvestigationProfileFormViewModel
{
    public int? Profile_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Profile Code")]
    public string Profile_Code { get; set; } = string.Empty;

    [Display(Name = "Profile / Package Name")]
    [StringLength(200, ErrorMessage = "Name cannot exceed 200 characters.")]
    public string Profile_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Profile Type is required.")]
    [Display(Name = "Profile Type")]
    public int Profile_Type { get; set; } = 1; // 1 = Profile, 2 = Package

    [Display(Name = "Profile Test")]
    public int? Test_ID { get; set; }

    [Required(ErrorMessage = "MRP is required.")]
    [Range(0, 1000000, ErrorMessage = "MRP must be a non-negative amount.")]
    [Display(Name = "MRP Price (₹)")]
    public decimal MRP { get; set; }

    [Range(0, 100, ErrorMessage = "Discount % must be between 0 and 100.")]
    [Display(Name = "Discount (%)")]
    public decimal Discount_Pct { get; set; }

    [Display(Name = "Effective Start Date")]
    [DataType(DataType.Date)]
    public DateTime? Effective_Start_Date { get; set; }

    [Display(Name = "Effective End Date")]
    [DataType(DataType.Date)]
    public DateTime? Effective_End_Date { get; set; }

    [Display(Name = "Age Comparison Operator")]
    public string? Age_Operator { get; set; } // Exact, GreaterEqual, LessEqual, Between

    [Display(Name = "Applicable Age (Years)")]
    [Range(0, 150, ErrorMessage = "Age must be between 0 and 150.")]
    public int? Applicable_Age { get; set; }

    [Required(ErrorMessage = "Gender is required.")]
    [Display(Name = "Applicable Gender")]
    public string Applicable_Gender { get; set; } = "All"; // All, Male, Female, Other

    [Display(Name = "TAT (Hours)")]
    [Range(0, 720, ErrorMessage = "TAT Hours must be between 0 and 720.")]
    public int Profile_TAT_Hours { get; set; } = 24;

    [Display(Name = "NABL Accredited")]
    public bool Profile_NABL_Accredited { get; set; }

    [Display(Name = "Report Print Sequence")]
    [Range(1, 999, ErrorMessage = "Sequence must be a positive integer.")]
    public int Report_Print_Sequence { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // JSON string for jQuery DataTables detail rows submit
    public string DetailsJson { get; set; } = "[]";

    // Options
    public List<SelectListItem> ProfileTypeOptions { get; set; } = [];
    public List<SelectListItem> ProfileTestOptions { get; set; } = [];
    public List<SelectListItem> AgeOperatorOptions { get; set; } = [];
    public List<SelectListItem> GenderOptions { get; set; } = [];
    public List<SelectListItem> AvailableTestOptions { get; set; } = [];
}

public class LabInvestigationProfileDetailRowViewModel
{
    public int? Detail_ID { get; set; }
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public int Sequence { get; set; } = 1;
    public decimal TestMRP { get; set; }
    public string Reporting_Type { get; set; } = string.Empty;
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
}
