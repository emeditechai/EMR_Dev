using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabInvestigationIndexViewModel
{
    public List<LabInvestigationModel> Investigations { get; set; } = [];
    public int? SelectedDepartmentId { get; set; }
    public int? SelectedCategoryId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> CategoryOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];

    public LabMasterDashboardViewModel? Dashboard { get; set; }
}

public class LabInvestigationFormViewModel
{
    public int Test_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Test Code")]
    public string Test_Code { get; set; } = string.Empty;

    [Required(ErrorMessage = "Test Name is required.")]
    [StringLength(200, ErrorMessage = "Test Name cannot exceed 200 characters.")]
    [Display(Name = "Test Name")]
    public string Test_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Department is required.")]
    [Display(Name = "Department")]
    public int Department_ID { get; set; }

    [Required(ErrorMessage = "Category is required.")]
    [Display(Name = "Test Category")]
    public int Category_ID { get; set; }

    [Display(Name = "Test Sub-Category")]
    public int? SubCategory_ID { get; set; }

    [Display(Name = "Sample Type")]
    public int? Sample_Type_ID { get; set; }

    [Display(Name = "Container Type")]
    public string? Container_Type { get; set; }

    [Display(Name = "Test Method")]
    public int? Method_ID { get; set; }

    [Display(Name = "Unit")]
    public int? Unit_ID { get; set; }

    [Required(ErrorMessage = "Reporting Type is required.")]
    [Display(Name = "Reporting Type")]
    public string Reporting_Type { get; set; } = "Numeric"; // Numeric / Text / Descriptive / Image / Template

    [Display(Name = "TAT (Hours)")]
    [Range(0, 720, ErrorMessage = "TAT Hours must be between 0 and 720.")]
    public int TAT_Hours { get; set; } = 24;

    [Display(Name = "NABL Accredited")]
    public bool NABL_Accredited { get; set; }

    [StringLength(100, ErrorMessage = "NABL Scope No cannot exceed 100 characters.")]
    [Display(Name = "NABL Scope Reference No.")]
    public string? NABL_Scope_No { get; set; }

    [Display(Name = "Is Outsourced Test")]
    public bool Is_Outsourced { get; set; }

    [Display(Name = "Is Profile Test")]
    public bool IsProfileTest { get; set; } = false;

    [Required(ErrorMessage = "Applicable Gender is required.")]
    [Display(Name = "Applicable Gender")]
    public string Applicable_Gender { get; set; } = "All";

    [Required(ErrorMessage = "Is Billable selection is required.")]
    [Display(Name = "Is Billable")]
    public bool Is_Billable { get; set; } = true;

    [Display(Name = "Age Comparison Operator")]
    public string? Age_Operator { get; set; }

    [Display(Name = "Applicable Age (Years)")]
    [Range(0, 150, ErrorMessage = "Age must be between 0 and 150.")]
    public int? Applicable_Age { get; set; }

    [Display(Name = "Is Fasting Required")]
    public bool Is_Fasting_Required { get; set; } = false;

    [Display(Name = "Consent Required")]
    public bool Is_Consent_Required { get; set; } = false;

    [Display(Name = "Sample Quantity")]
    [Range(0, 10000, ErrorMessage = "Sample Quantity must be non-negative.")]
    public decimal? Sample_Quantity { get; set; }

    [Display(Name = "Sample Quantity Unit")]
    public int? Sample_Quantity_Unit_ID { get; set; }

    [Display(Name = "Reported Duration")]
    [Range(1, 365, ErrorMessage = "Reported duration must be between 1 and 365.")]
    public int? Reported_Duration_Value { get; set; }

    [Display(Name = "Reported Duration Unit")]
    public string? Reported_Duration_Unit { get; set; } = "Days";

    [Required(ErrorMessage = "MRP is required.")]
    [Range(0, 1000000, ErrorMessage = "MRP must be a valid non-negative amount.")]
    [Display(Name = "MRP (₹)")]
    public decimal MRP { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown options
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> CategoryOptions { get; set; } = [];
    public List<SelectListItem> SubCategoryOptions { get; set; } = [];
    public List<SelectListItem> SampleTypeOptions { get; set; } = [];
    public List<SelectListItem> MethodOptions { get; set; } = [];
    public List<SelectListItem> UnitOptions { get; set; } = [];
    public List<SelectListItem> ReportingTypeOptions { get; set; } = [];
    public List<SelectListItem> ProfileTestOptions { get; set; } = [];
    public List<SelectListItem> GenderOptions { get; set; } = [];
    public List<SelectListItem> IsBillableOptions { get; set; } = [];
    public List<SelectListItem> AgeOperatorOptions { get; set; } = [];
    public List<SelectListItem> FastingOptions { get; set; } = [];
    public List<SelectListItem> ConsentOptions { get; set; } = [];
    public List<SelectListItem> DurationUnitOptions { get; set; } = [];
}
