using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabExpertRuleIndexViewModel
{
    public List<LabExpertRuleModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public int? SelectedOrganism_ID { get; set; }
    public List<SelectListItem> Organism_IDFilterOptions { get; set; } = [];
    public int? SelectedAntibiotic_ID { get; set; }
    public List<SelectListItem> Antibiotic_IDFilterOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabExpertRuleFormViewModel
{
    public static readonly string[] Rule_TypeOptions = ["Intrinsic Resistance", "MRSA Indicator", "ESBL Indicator", "CRE Indicator", "VRE Indicator", "Custom Alert"];
    public static readonly string[] Organism_CategoryOptions = ["Enterobacteriaceae", "Non-Fermenter", "Gram Positive Cocci", "Gram Positive Bacilli", "Anaerobes", "Fastidious Gram Negative", "Mycobacteria", "Fungal", "Other"];
    public static readonly string[] Trigger_ResultOptions = ["S", "I", "R"];
    public static readonly string[] Rule_ActionOptions = ["Warn Only", "Report as Resistant", "Block Approval"];

    public int Rule_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Rule Code")]
    public string? Rule_Code { get; set; }

    [Required(ErrorMessage = "Rule Type is required.")]
    [StringLength(50, ErrorMessage = "Rule Type cannot exceed 50 characters.")]
    [Display(Name = "Rule Type")]
    public string Rule_Type { get; set; } = string.Empty;

    [StringLength(50, ErrorMessage = "Organism Category cannot exceed 50 characters.")]
    [Display(Name = "Organism Category")]
    public string? Organism_Category { get; set; }

    [Display(Name = "Organism")]
    public int? Organism_ID { get; set; }

    [Range(1, int.MaxValue, ErrorMessage = "Antibiotic is required.")]
    [Display(Name = "Antibiotic")]
    public int Antibiotic_ID { get; set; }

    [Required(ErrorMessage = "Trigger When Result Is is required.")]
    [StringLength(5, ErrorMessage = "Trigger When Result Is cannot exceed 5 characters.")]
    [Display(Name = "Trigger When Result Is")]
    public string Trigger_Result { get; set; } = string.Empty;

    [Required(ErrorMessage = "Action is required.")]
    [StringLength(30, ErrorMessage = "Action cannot exceed 30 characters.")]
    [Display(Name = "Action")]
    public string Rule_Action { get; set; } = string.Empty;

    [Required(ErrorMessage = "Alert Message is required.")]
    [StringLength(300, ErrorMessage = "Alert Message cannot exceed 300 characters.")]
    [Display(Name = "Alert Message")]
    public string Alert_Message { get; set; } = string.Empty;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> Organism_IDOptions { get; set; } = [];
    public List<SelectListItem> Antibiotic_IDOptions { get; set; } = [];
}
