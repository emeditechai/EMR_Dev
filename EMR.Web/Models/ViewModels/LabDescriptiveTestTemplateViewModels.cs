using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabDescriptiveTestTemplateIndexViewModel
{
    public List<ApiClients.Models.LabDescriptiveTestTemplateModel> Templates { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabDescriptiveTestTemplateFormViewModel
{
    public int Template_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Test is required.")]
    [Display(Name = "Test (Radiology)")]
    public int Test_ID { get; set; }

    public string? Test_Name { get; set; }

    [Required(ErrorMessage = "Section Name is required.")]
    [StringLength(200, ErrorMessage = "Section Name cannot exceed 200 characters.")]
    [Display(Name = "Section Name")]
    public string Section_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Section Sequence is required.")]
    [Range(1, 999, ErrorMessage = "Section Sequence must be between 1 and 999.")]
    [Display(Name = "Section Sequence")]
    public int Section_Sequence { get; set; } = 1;

    [Display(Name = "Mandatory")]
    public bool Is_Mandatory { get; set; }

    [Display(Name = "Default Content (HTML)")]
    public string? Default_Content_Html { get; set; }

    [StringLength(500, ErrorMessage = "Placeholder Tags cannot exceed 500 characters.")]
    [Display(Name = "Placeholder Tags")]
    public string? Placeholder_Tags { get; set; }

    [StringLength(50)]
    [Display(Name = "Modality")]
    public string? Modality { get; set; }

    [StringLength(100)]
    [Display(Name = "Body Part / Region")]
    public string? Body_Part { get; set; }

    [StringLength(20)]
    [Display(Name = "Laterality")]
    public string? Laterality { get; set; }

    [Display(Name = "Contrast Required")]
    public bool Contrast_Required { get; set; }

    [StringLength(100)]
    [Display(Name = "Contrast Agent")]
    public string? Contrast_Agent { get; set; }

    [StringLength(200)]
    [Display(Name = "Views / Projections")]
    public string? Views_Projections { get; set; }

    [StringLength(1000)]
    [Display(Name = "Preparation Instructions")]
    public string? Preparation_Instructions { get; set; }

    [Display(Name = "Status")]
    public bool IsActive { get; set; } = true;
}
