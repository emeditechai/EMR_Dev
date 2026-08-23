using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabSampleTypeIndexViewModel
{
    public List<ApiClients.Models.LabSampleTypeModel> SampleTypes { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public string? SelectedContainerType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> ContainerTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabSampleTypeFormViewModel
{
    public int Sample_Type_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; } = 1;

    [Required(ErrorMessage = "Sample Name is required.")]
    [StringLength(150, ErrorMessage = "Sample Name cannot exceed 150 characters.")]
    [Display(Name = "Sample Name")]
    public string Sample_Name { get; set; } = string.Empty;

    [Display(Name = "Sample Code")]
    public string? Sample_Code { get; set; }

    [Required(ErrorMessage = "Container Type is required.")]
    [Display(Name = "Container Type")]
    public ApiClients.Models.ContainerTypeEnum Container_Type { get; set; } = ApiClients.Models.ContainerTypeEnum.RedTopVial;

    [Required(ErrorMessage = "Volume Value is required.")]
    [Range(0.01, 1000.0, ErrorMessage = "Volume value must be a positive numerical value.")]
    [Display(Name = "Volume Value")]
    public decimal Volume_Value { get; set; } = 1.00m;

    [Display(Name = "Volume Unit")]
    public int? Unit_ID { get; set; }

    public string? Volume_Unit { get; set; }

    [Display(Name = "Storage Temperature (°C)")]
    public string? Storage_Temperature { get; set; }

    [Display(Name = "Rejection Criteria")]
    [StringLength(500, ErrorMessage = "Rejection Criteria cannot exceed 500 characters.")]
    public string? Rejection_Criteria { get; set; }

    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> ContainerTypeOptions { get; set; } = [];
    public List<SelectListItem> UnitOptions { get; set; } = [];
}
