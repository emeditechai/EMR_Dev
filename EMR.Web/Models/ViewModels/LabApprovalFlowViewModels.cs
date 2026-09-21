using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabApprovalFlowIndexViewModel
{
    public List<LabApprovalFlowModel> Flows { get; set; } = [];

    // Filters (BranchScope: null = all, 0 = company-wide only, >0 = that branch)
    public int? SelectedBranchScope { get; set; }
    public int? SelectedDepartmentId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> BranchScopeOptions { get; set; } = [];
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];

    // KPI cards (whole company, not the filtered list)
    public int TotalCount { get; set; }
    public int ActiveCount { get; set; }
    public int CompanyDefaultCount { get; set; }
    public int OverrideCount { get; set; }
    public int MultiLevelCount { get; set; }
}

/// <summary>One approval level as edited on the form. Three are always rendered; only Required_Levels are saved.</summary>
public class LabApprovalFlowLevelForm
{
    public int LevelNo { get; set; }

    [StringLength(100, ErrorMessage = "Level title cannot exceed 100 characters.")]
    public string? Title { get; set; }

    public List<int> ApproverIds { get; set; } = new();
}

/// <summary>A test category offered in the form; the department drives which ones are shown.</summary>
public class LabApprovalCategoryOption
{
    public int CategoryId { get; set; }
    public string CategoryName { get; set; } = string.Empty;
    public int? DepartmentId { get; set; }
}

public class LabApprovalFlowFormViewModel
{
    public int Flow_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    /// <summary>Read-only. Generated on save (e.g. LAF0001).</summary>
    [Display(Name = "Flow Code")]
    public string? Flow_Code { get; set; }

    [Required(ErrorMessage = "Flow name is required.")]
    [StringLength(150, ErrorMessage = "Flow name cannot exceed 150 characters.")]
    [Display(Name = "Flow Name")]
    public string Flow_Name { get; set; } = string.Empty;

    [Range(1, 3, ErrorMessage = "Approval levels must be 1, 2 or 3.")]
    [Display(Name = "Number of Approval Levels")]
    public int Required_Levels { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? Branch_ID { get; set; }

    [Display(Name = "Department")]
    public int? Department_ID { get; set; }

    /// <summary>Selected test categories (empty = every category). Saved as a comma-separated list.</summary>
    [Display(Name = "Test Categories")]
    public List<int> Category_IDs { get; set; } = new();

    [Display(Name = "Allow the same approver on more than one level")]
    public bool Allow_Same_Approver { get; set; }

    [Display(Name = "Active Status")]
    public bool Status { get; set; } = true;

    public List<LabApprovalFlowLevelForm> Levels { get; set; } = new()
    {
        new() { LevelNo = 1 }, new() { LevelNo = 2 }, new() { LevelNo = 3 }
    };

    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<LabApprovalCategoryOption> CategoryOptions { get; set; } = [];

    /// <summary>Pathologists that can be picked for the current scope (plus any already selected).</summary>
    public List<LabApprovalEligibleApproverModel> Approvers { get; set; } = [];
    /// <summary>Users already selected that are no longer eligible for the scope - shown with a warning.</summary>
    public HashSet<int> IneligibleSelectedIds { get; set; } = [];
    /// <summary>Active pathologists that do NOT match the scope, with the reason - shown so nobody wonders why they are missing.</summary>
    public List<LabApprovalEligibleApproverModel> NotListedApprovers { get; set; } = [];
}
