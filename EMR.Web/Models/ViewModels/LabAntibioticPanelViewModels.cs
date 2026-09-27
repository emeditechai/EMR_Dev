using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabAntibioticPanelIndexViewModel
{
    public List<LabAntibioticPanelModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public int? SelectedSample_Type_ID { get; set; }
    public List<SelectListItem> Sample_Type_IDFilterOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabAntibioticPanelFormViewModel
{
    public static readonly string[] Gram_TypeOptions = ["Gram Positive", "Gram Negative", "Not Applicable"];
    public static readonly string[] Organism_CategoryOptions = ["Enterobacteriaceae", "Non-Fermenter", "Gram Positive Cocci", "Gram Positive Bacilli", "Anaerobes", "Fastidious Gram Negative", "Mycobacteria", "Fungal", "Other"];

    public int Panel_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Panel Code")]
    public string? Panel_Code { get; set; }

    [Required(ErrorMessage = "Panel Name is required.")]
    [StringLength(150, ErrorMessage = "Panel Name cannot exceed 150 characters.")]
    [Display(Name = "Panel Name")]
    public string Panel_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Gram Type is required.")]
    [StringLength(30, ErrorMessage = "Gram Type cannot exceed 30 characters.")]
    [Display(Name = "Gram Type")]
    public string Gram_Type { get; set; } = string.Empty;

    [StringLength(50, ErrorMessage = "Organism Category cannot exceed 50 characters.")]
    [Display(Name = "Organism Category")]
    public string? Organism_Category { get; set; }

    [Display(Name = "Specimen Type")]
    public int? Sample_Type_ID { get; set; }

    [StringLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Display(Name = "Antibiotics")]
    public List<int> Antibiotic_IDs { get; set; } = [];

    public List<int> Antibiotic_Tiers { get; set; } = [];

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> Sample_Type_IDOptions { get; set; } = [];
    public List<SelectListItem> Antibiotic_IDsOptions { get; set; } = [];
}
