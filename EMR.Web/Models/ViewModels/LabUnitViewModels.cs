using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabUnitIndexViewModel
{
    public List<ApiClients.Models.LabUnitModel> Units { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabUnitFormViewModel
{
    public int Unit_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Unit Name is required.")]
    [StringLength(150, ErrorMessage = "Unit Name cannot exceed 150 characters.")]
    [Display(Name = "Unit Name")]
    public string Unit_Name { get; set; } = string.Empty;

    [Display(Name = "Unit Code")]
    public string? Unit_Code { get; set; }

    [Display(Name = "Unit Symbol")]
    [StringLength(50, ErrorMessage = "Unit Symbol cannot exceed 50 characters.")]
    public string? Unit_Symbol { get; set; }

    [Display(Name = "Conversion Factor")]
    [Range(0.000001, 1000000.0, ErrorMessage = "Conversion Factor must be a positive decimal value.")]
    public decimal Conversion_Factor { get; set; } = 1.0m;

    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;
}
