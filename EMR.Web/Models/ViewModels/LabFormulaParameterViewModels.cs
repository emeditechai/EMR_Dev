using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabFormulaParameterIndexViewModel
{
    public List<ApiClients.Models.LabFormulaParameterModel> FormulaParameters { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabFormulaParameterFormViewModel
{
    public int Parameter_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Test is required.")]
    [Display(Name = "Target Test (Calculated Parameter)")]
    public int Test_ID { get; set; }

    public string? Test_Name { get; set; }

    [Required(ErrorMessage = "Formula Expression is required.")]
    [StringLength(1000, ErrorMessage = "Formula Expression cannot exceed 1000 characters.")]
    [Display(Name = "Formula Expression")]
    public string Formula_Expression { get; set; } = string.Empty;

    [Required(ErrorMessage = "Rounding Precision is required.")]
    [Range(0, 10, ErrorMessage = "Rounding Precision must be between 0 and 10.")]
    [Display(Name = "Rounding Precision (Decimal Places)")]
    public int Rounding_Precision { get; set; } = 2;

    [StringLength(500, ErrorMessage = "Validity Condition cannot exceed 500 characters.")]
    [Display(Name = "Validity Condition")]
    public string? Validity_Condition { get; set; }

    [Display(Name = "Status")]
    public bool IsActive { get; set; } = true;
}
