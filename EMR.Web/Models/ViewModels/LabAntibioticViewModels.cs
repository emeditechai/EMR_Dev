using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabAntibioticIndexViewModel
{
    public List<LabAntibioticModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabAntibioticFormViewModel
{
    public static readonly string[] Antibiotic_ClassOptions = ["Penicillins", "Beta-lactam Combinations", "Cephalosporins", "Carbapenems", "Monobactams", "Aminoglycosides", "Quinolones", "Macrolides", "Lincosamides", "Tetracyclines", "Glycopeptides", "Oxazolidinones", "Polymyxins", "Sulfonamides", "Nitrofurans", "Phosphonic Acids", "Antifungals", "Other"];
    public static readonly string[] RouteOptions = ["Oral", "IV", "IM", "Oral / IV", "IV / IM", "Topical", "Urinary Only"];

    public int Antibiotic_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Antibiotic Code")]
    public string? Antibiotic_Code { get; set; }

    [Required(ErrorMessage = "Antibiotic Name is required.")]
    [StringLength(150, ErrorMessage = "Antibiotic Name cannot exceed 150 characters.")]
    [Display(Name = "Antibiotic Name")]
    public string Antibiotic_Name { get; set; } = string.Empty;

    [StringLength(10, ErrorMessage = "Abbreviation cannot exceed 10 characters.")]
    [Display(Name = "Abbreviation")]
    public string? Abbreviation { get; set; }

    [Required(ErrorMessage = "Antibiotic Class is required.")]
    [StringLength(50, ErrorMessage = "Antibiotic Class cannot exceed 50 characters.")]
    [Display(Name = "Antibiotic Class")]
    public string Antibiotic_Class { get; set; } = string.Empty;

    [Required(ErrorMessage = "Route is required.")]
    [StringLength(30, ErrorMessage = "Route cannot exceed 30 characters.")]
    [Display(Name = "Route")]
    public string Route { get; set; } = string.Empty;

    [StringLength(20, ErrorMessage = "WHONET Code cannot exceed 20 characters.")]
    [Display(Name = "WHONET Code")]
    public string? WHONET_Code { get; set; }

    [StringLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;


}
