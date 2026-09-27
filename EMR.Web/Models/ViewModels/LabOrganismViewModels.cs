using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabOrganismIndexViewModel
{
    public List<LabOrganismModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabOrganismFormViewModel
{
    public static readonly string[] Gram_TypeOptions = ["Gram Positive", "Gram Negative", "Not Applicable"];
    public static readonly string[] Organism_TypeOptions = ["Bacteria", "Fungus", "Parasite", "Virus"];
    public static readonly string[] Organism_CategoryOptions = ["Enterobacteriaceae", "Non-Fermenter", "Gram Positive Cocci", "Gram Positive Bacilli", "Anaerobes", "Fastidious Gram Negative", "Mycobacteria", "Fungal", "Other"];

    public int Organism_ID { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Organism Code")]
    public string? Organism_Code { get; set; }

    [Required(ErrorMessage = "Organism Name is required.")]
    [StringLength(150, ErrorMessage = "Organism Name cannot exceed 150 characters.")]
    [Display(Name = "Organism Name")]
    public string Organism_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Gram Type is required.")]
    [StringLength(30, ErrorMessage = "Gram Type cannot exceed 30 characters.")]
    [Display(Name = "Gram Type")]
    public string Gram_Type { get; set; } = string.Empty;

    [Required(ErrorMessage = "Organism Type is required.")]
    [StringLength(30, ErrorMessage = "Organism Type cannot exceed 30 characters.")]
    [Display(Name = "Organism Type")]
    public string Organism_Type { get; set; } = string.Empty;

    [Required(ErrorMessage = "Category is required.")]
    [StringLength(50, ErrorMessage = "Category cannot exceed 50 characters.")]
    [Display(Name = "Category")]
    public string Organism_Category { get; set; } = string.Empty;

    [StringLength(10, ErrorMessage = "WHONET Code cannot exceed 10 characters.")]
    [Display(Name = "WHONET Code")]
    public string? WHONET_Code { get; set; }

    [StringLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;


}
