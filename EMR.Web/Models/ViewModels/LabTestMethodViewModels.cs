using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabTestMethodIndexViewModel
{
    public List<ApiClients.Models.LabTestMethodModel> Methods { get; set; } = [];
    public int? SelectedDepartmentId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabTestMethodFormViewModel
{
    public int Method_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Department is required.")]
    [Display(Name = "Department")]
    public int Department_ID { get; set; }

    [Required(ErrorMessage = "Method Name is required.")]
    [StringLength(150, ErrorMessage = "Method Name cannot exceed 150 characters.")]
    [Display(Name = "Method Name")]
    public string Method_Name { get; set; } = string.Empty;

    [Display(Name = "Method Code")]
    public string? Method_Code { get; set; }

    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> DepartmentOptions { get; set; } = [];
}
