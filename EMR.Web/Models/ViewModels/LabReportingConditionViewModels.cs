using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabReportingConditionIndexViewModel
{
    public List<LabReportingConditionModel> Conditions { get; set; } = [];

    // Filters (BranchScope: null = all, 0 = company-wide only, >0 = that branch)
    public int? SelectedBranchScope { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> BranchScopeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];

    // KPI cards (whole company, not the filtered list)
    public int TotalCount { get; set; }
    public int ActiveCount { get; set; }
    public int CompanyWideCount { get; set; }
    public int BranchSpecificCount { get; set; }
    public int BranchesWithOwnSet { get; set; }
}

public class LabReportingConditionFormViewModel
{
    public int Condition_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    /// <summary>Read-only. Generated on save (e.g. LCOR0001).</summary>
    [Display(Name = "Condition Code")]
    public string? Condition_Code { get; set; }

    [Display(Name = "Applies To")]
    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Condition text is required.")]
    [StringLength(1000, ErrorMessage = "Condition text cannot exceed 1000 characters.")]
    [Display(Name = "Condition Text")]
    public string Condition_Text { get; set; } = string.Empty;

    [Required(ErrorMessage = "Display Order is required.")]
    [Range(1, 99999, ErrorMessage = "Display Order must be a positive integer.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> BranchOptions { get; set; } = [];
}
