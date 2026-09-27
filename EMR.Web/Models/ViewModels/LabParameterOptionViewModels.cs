using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabParameterOptionIndexViewModel
{
    public List<LabParameterOptionModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public int? SelectedTest_ID { get; set; }
    public List<SelectListItem> Test_IDFilterOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabParameterOptionFormViewModel
{


    public int Option_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Option Code")]
    public string? Option_Code { get; set; }

    [Range(1, int.MaxValue, ErrorMessage = "Test (Parameter) is required.")]
    [Display(Name = "Test (Parameter)")]
    public int Test_ID { get; set; }

    [Required(ErrorMessage = "Option Text is required.")]
    [StringLength(100, ErrorMessage = "Option Text cannot exceed 100 characters.")]
    [Display(Name = "Option Text")]
    public string Option_Text { get; set; } = string.Empty;

    [Range(1, 999, ErrorMessage = "Display Order must be between 1 and 999.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Abnormal Value")]
    public bool Is_Abnormal { get; set; } = false;

    [Display(Name = "Default Selection")]
    public bool Is_Default { get; set; } = false;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> Test_IDOptions { get; set; } = [];
}
