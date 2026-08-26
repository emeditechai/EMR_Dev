using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabTestCategoryIndexViewModel
{
    public List<ApiClients.Models.LabTestCategoryModel> Categories { get; set; } = [];
    public int? SelectedDepartmentId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabTestCategoryFormViewModel
{
    public int Category_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Department is required.")]
    [Display(Name = "Department")]
    public int Department_ID { get; set; }

    [Required(ErrorMessage = "Category Name is required.")]
    [StringLength(150, ErrorMessage = "Category Name cannot exceed 150 characters.")]
    [Display(Name = "Category Name")]
    public string Category_Name { get; set; } = string.Empty;

    [Display(Name = "Category Code")]
    public string? Category_Code { get; set; }

    [Required(ErrorMessage = "Display Order is required.")]
    [Range(1, 99999, ErrorMessage = "Display Order must be a positive integer.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> DepartmentOptions { get; set; } = [];
}
