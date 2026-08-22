using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class ConsentMasterListItemViewModel
{
    public int Consent_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string ConsentType { get; set; } = string.Empty;
    public string Type { get; set; } = string.Empty; // IPD, OPD, LAB, MED
    public int? Procedure_ID { get; set; }
    public string? ProcedureCode { get; set; }
    public string? ProcedureName { get; set; }
    public string? ProcedureCategory { get; set; }
    public string Language { get; set; } = "English";
    public string ConsentTemplateContent { get; set; } = string.Empty;
    public string Version { get; set; } = "1.0";
    public string ValidityPeriod { get; set; } = "Per Admission";
    public bool WitnessRequired { get; set; } = true;
    public bool Status { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class ConsentMasterFormViewModel
{
    public int Consent_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int Branch_ID { get; set; }

    [Required(ErrorMessage = "Consent Type is required.")]
    [MaxLength(100, ErrorMessage = "Maximum 100 characters allowed.")]
    [Display(Name = "Consent Type")]
    public string ConsentType { get; set; } = string.Empty;

    [Required(ErrorMessage = "Department Type is required.")]
    [MaxLength(20, ErrorMessage = "Maximum 20 characters allowed.")]
    [Display(Name = "Department Type")]
    public string Type { get; set; } = "IPD"; // IPD, OPD, LAB, MED

    [Display(Name = "Linked Procedure (Optional for IPD)")]
    public int? Procedure_ID { get; set; }

    [Required(ErrorMessage = "Language is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [Display(Name = "Language")]
    public string Language { get; set; } = "English";

    [Required(ErrorMessage = "Consent Template Content is required.")]
    [Display(Name = "Consent Template Content")]
    public string ConsentTemplateContent { get; set; } = string.Empty;

    [Required(ErrorMessage = "Version is required.")]
    [MaxLength(20, ErrorMessage = "Maximum 20 characters allowed.")]
    [Display(Name = "Template Version")]
    public string Version { get; set; } = "1.0";

    [Required(ErrorMessage = "Validity Period is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [Display(Name = "Validity Period")]
    public string ValidityPeriod { get; set; } = "Per Admission";

    [Display(Name = "Witness Required")]
    public bool WitnessRequired { get; set; } = true;

    [Display(Name = "Active Status")]
    public bool Status { get; set; } = true;

    // Dropdown collections
    public List<SelectListItem> DepartmentTypeOptions { get; set; } = [];
    public List<SelectListItem> ConsentTypeOptions { get; set; } = [];
    public List<SelectListItem> LanguageOptions { get; set; } = [];
    public List<SelectListItem> ValidityPeriodOptions { get; set; } = [];
    public List<SelectListItem> ProcedureOptions { get; set; } = [];
}

public class ConsentMasterDetailsViewModel : ConsentMasterListItemViewModel
{
}

public class ConsentMasterIndexViewModel
{
    public IEnumerable<ConsentMasterListItemViewModel> Items { get; set; } = [];
    public string? SelectedType { get; set; }
    public string? SelectedConsentType { get; set; }
    public string? SelectedLanguage { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> DepartmentTypeOptions { get; set; } = [];
    public List<SelectListItem> ConsentTypeOptions { get; set; } = [];
    public List<SelectListItem> LanguageOptions { get; set; } = [];
}

public class ConsentProcedureOptionViewModel
{
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string? ProcedureCategory { get; set; }
    public string? DepartmentName { get; set; }
    public string? SpecialityName { get; set; }
}
