using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabTestSubCategoryIndexViewModel
{
    public List<ApiClients.Models.LabTestSubCategoryModel> SubCategories { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public int? SelectedCategoryId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> CategoryOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabTestSubCategoryFormViewModel
{
    public int SubCategory_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; } = 1;

    [Required(ErrorMessage = "Test Category is required.")]
    [Display(Name = "Test Category")]
    public int Category_ID { get; set; }

    [Required(ErrorMessage = "Sub Category Name is required.")]
    [StringLength(150, ErrorMessage = "Sub Category Name cannot exceed 150 characters.")]
    [Display(Name = "Sub Category Name")]
    public string SubCategory_Name { get; set; } = string.Empty;

    [Display(Name = "Sub Category Code")]
    public string? SubCategory_Code { get; set; }

    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> CategoryOptions { get; set; } = [];
}
