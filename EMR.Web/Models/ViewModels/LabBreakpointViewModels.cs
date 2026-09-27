using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabBreakpointIndexViewModel
{
    public List<LabBreakpointModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public int? SelectedOrganism_ID { get; set; }
    public List<SelectListItem> Organism_IDFilterOptions { get; set; } = [];
    public int? SelectedAntibiotic_ID { get; set; }
    public List<SelectListItem> Antibiotic_IDFilterOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabBreakpointFormViewModel
{
    public static readonly string[] Organism_CategoryOptions = ["Enterobacteriaceae", "Non-Fermenter", "Gram Positive Cocci", "Gram Positive Bacilli", "Anaerobes", "Fastidious Gram Negative", "Mycobacteria", "Fungal", "Other"];
    public static readonly string[] StandardOptions = ["CLSI", "EUCAST"];
    public static readonly string[] MethodOptions = ["MIC (mg/L)", "Disk Diffusion (mm)"];
    public static readonly string[] Specimen_ScopeOptions = ["All Specimens", "Urine (Uncomplicated UTI)", "Non-Meningitis", "Meningitis"];

    public int Breakpoint_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Breakpoint Code")]
    public string? Breakpoint_Code { get; set; }

    [Required(ErrorMessage = "Organism Category is required.")]
    [StringLength(50, ErrorMessage = "Organism Category cannot exceed 50 characters.")]
    [Display(Name = "Organism Category")]
    public string Organism_Category { get; set; } = string.Empty;

    [Display(Name = "Specific Organism")]
    public int? Organism_ID { get; set; }

    [Range(1, int.MaxValue, ErrorMessage = "Antibiotic is required.")]
    [Display(Name = "Antibiotic")]
    public int Antibiotic_ID { get; set; }

    [Required(ErrorMessage = "Standard is required.")]
    [StringLength(20, ErrorMessage = "Standard cannot exceed 20 characters.")]
    [Display(Name = "Standard")]
    public string Standard { get; set; } = string.Empty;

    [Required(ErrorMessage = "Standard Version is required.")]
    [StringLength(50, ErrorMessage = "Standard Version cannot exceed 50 characters.")]
    [Display(Name = "Standard Version")]
    public string Standard_Version { get; set; } = string.Empty;

    [Required(ErrorMessage = "Method is required.")]
    [StringLength(30, ErrorMessage = "Method cannot exceed 30 characters.")]
    [Display(Name = "Method")]
    public string Method { get; set; } = string.Empty;

    [Required(ErrorMessage = "Specimen Scope is required.")]
    [StringLength(50, ErrorMessage = "Specimen Scope cannot exceed 50 characters.")]
    [Display(Name = "Specimen Scope")]
    public string Specimen_Scope { get; set; } = string.Empty;

    [Display(Name = "S Breakpoint")]
    public decimal? S_Breakpoint { get; set; }

    [Display(Name = "R Breakpoint")]
    public decimal? R_Breakpoint { get; set; }

    [StringLength(500, ErrorMessage = "Remarks cannot exceed 500 characters.")]
    [Display(Name = "Remarks")]
    public string? Remarks { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> Organism_IDOptions { get; set; } = [];
    public List<SelectListItem> Antibiotic_IDOptions { get; set; } = [];
}
