using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabReferenceRangeIndexViewModel
{
    public List<ApiClients.Models.LabReferenceRangeModel> ReferenceRanges { get; set; } = [];
    public int? SelectedTestId { get; set; }
    public string? SelectedGender { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> TestOptions { get; set; } = [];
    public List<SelectListItem> GenderOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabReferenceRangeFormViewModel
{
    public int RefRange_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Investigation Test is required.")]
    [Display(Name = "Investigation Test")]
    public int Test_ID { get; set; }

    public string? Test_Name { get; set; }

    [Display(Name = "Test Method")]
    public int? Method_ID { get; set; }

    [Display(Name = "Method Name")]
    public string? Method_Name { get; set; }

    [Required(ErrorMessage = "Unit is required.")]
    [Display(Name = "Unit")]
    public int Unit_ID { get; set; }

    [Range(0, 150, ErrorMessage = "Age From must be between 0 and 150.")]
    [Display(Name = "Age From")]
    public decimal? Age_From { get; set; }

    [Range(0, 150, ErrorMessage = "Age To must be between 0 and 150.")]
    [Display(Name = "Age To")]
    public decimal? Age_To { get; set; }

    [Display(Name = "Age Unit")]
    public string Age_Unit { get; set; } = "Years";

    [Display(Name = "Gender")]
    public string Gender { get; set; } = "All";

    [Display(Name = "Pregnancy Trimester")]
    public string? Pregnancy_Trimester { get; set; } = "Not Applicable";

    [Display(Name = "Low Value")]
    public decimal? Low_Value { get; set; }

    [Display(Name = "High Value")]
    public decimal? High_Value { get; set; }

    [StringLength(1000, ErrorMessage = "Special Remarks cannot exceed 1000 characters.")]
    [Display(Name = "Special Remarks")]
    public string? Special_Remarks { get; set; }

    [StringLength(500, ErrorMessage = "Range Source cannot exceed 500 characters.")]
    [Display(Name = "Range Source")]
    public string? Range_Source { get; set; }

    [Required(ErrorMessage = "Effective From date is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime? Effective_To { get; set; }

    [Display(Name = "Common for All (Single Range)")]
    public bool Is_Common_For_All { get; set; } = false;

    public string? RangeItemsJson { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown Select Lists
    public List<SelectListItem> TestOptions { get; set; } = [];
    public List<SelectListItem> UnitOptions { get; set; } = [];
    public List<SelectListItem> AgeUnitOptions { get; set; } = [];
    public List<SelectListItem> GenderOptions { get; set; } = [];
    public List<SelectListItem> TrimesterOptions { get; set; } = [];
}
