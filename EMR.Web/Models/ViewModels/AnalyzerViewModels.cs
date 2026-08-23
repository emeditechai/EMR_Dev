using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.Models.ViewModels;

public class AnalyzerListViewModel
{
    public List<AnalyzerListItem> Items { get; set; } = new();
    public int? FilterBranchId { get; set; }
    public int? FilterDepartmentId { get; set; }
    public string? FilterInterfaceProtocol { get; set; }
    public bool? FilterStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> BranchOptions { get; set; } = new();
    public List<SelectListItem> DepartmentOptions { get; set; } = new();
    public List<SelectListItem> InterfaceProtocolOptions { get; set; } = new();
    public List<SelectListItem> StatusOptions { get; set; } = new();

    public int TotalCount => Items.Count;
    public int ActiveCount => Items.Count(x => x.Status);
    public int InactiveCount => Items.Count(x => !x.Status);
    public int Hl7Count => Items.Count(x => string.Equals(x.Interface_Protocol, "HL7", StringComparison.OrdinalIgnoreCase));
    public int AstmCount => Items.Count(x => string.Equals(x.Interface_Protocol, "ASTM", StringComparison.OrdinalIgnoreCase));
    public int ManualCount => Items.Count(x => string.Equals(x.Interface_Protocol, "Manual Entry", StringComparison.OrdinalIgnoreCase));
}

public class AnalyzerFormViewModel
{
    public int? Analyzer_ID { get; set; }

    [Required(ErrorMessage = "Branch is required.")]
    [Display(Name = "Branch")]
    public int Branch_ID { get; set; }

    [Required(ErrorMessage = "Department is required.")]
    [Display(Name = "Department (Laboratory)")]
    public int Department_ID { get; set; }

    [Required(ErrorMessage = "Analyzer / Instrument Name is required.")]
    [MaxLength(150, ErrorMessage = "Analyzer Name cannot exceed 150 characters.")]
    [Display(Name = "Analyzer Name")]
    public string Analyzer_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Interface Protocol is required.")]
    [Display(Name = "Interface Protocol")]
    public string Interface_Protocol { get; set; } = "HL7"; // HL7 / ASTM / Manual Entry

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> BranchOptions { get; set; } = new();
    public List<SelectListItem> DepartmentOptions { get; set; } = new();
    public List<SelectListItem> InterfaceProtocolOptions { get; set; } = new();
}

public class AnalyzerDetailViewModel
{
    public AnalyzerDetail Item { get; set; } = new();
}
