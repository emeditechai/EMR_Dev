using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class ProcedureListItemViewModel
{
    public int ProcedureId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string? DepartmentCode { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string? SpecialityCode { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public int DurationHours { get; set; }
    public int DurationMinutes { get; set; }
    public int DurationSeconds { get; set; }
    public bool AnaesthesiaRequired { get; set; }
    public bool ConsentRequired { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }

    public string DurationFormatted => $"{DurationHours:D2}h {DurationMinutes:D2}m {(DurationSeconds > 0 ? $"{DurationSeconds:D2}s" : "")}".Trim();
}

public class ProcedureFormViewModel
{
    public int ProcedureId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Department is required")]
    [Display(Name = "IPD Department")]
    public int DepartmentId { get; set; }

    [Required(ErrorMessage = "Speciality is required")]
    [Display(Name = "Doctor Speciality")]
    public int SpecialityId { get; set; }

    [Required(ErrorMessage = "Procedure Code is required")]
    [StringLength(50, ErrorMessage = "Procedure Code cannot exceed 50 characters")]
    [Display(Name = "Procedure Code")]
    public string ProcedureCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Procedure Name is required")]
    [StringLength(200, ErrorMessage = "Procedure Name cannot exceed 200 characters")]
    [Display(Name = "Procedure Name")]
    public string ProcedureName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Procedure Category is required")]
    [StringLength(100)]
    [Display(Name = "Procedure Category")]
    public string ProcedureCategory { get; set; } = string.Empty;

    [Range(0, 72, ErrorMessage = "Duration Hours must be between 0 and 72")]
    [Display(Name = "Hours")]
    public int DurationHours { get; set; } = 0;

    [Range(0, 59, ErrorMessage = "Duration Minutes must be between 0 and 59")]
    [Display(Name = "Minutes")]
    public int DurationMinutes { get; set; } = 0;

    [Range(0, 59, ErrorMessage = "Duration Seconds must be between 0 and 59")]
    [Display(Name = "Seconds")]
    public int DurationSeconds { get; set; } = 0;

    [Display(Name = "Anaesthesia Required")]
    public bool AnaesthesiaRequired { get; set; } = false;

    [Display(Name = "Consent Required")]
    public bool ConsentRequired { get; set; } = true;

    [StringLength(500)]
    [Display(Name = "Description / Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Is Active")]
    public bool IsActive { get; set; } = true;

    // Dropdowns
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> ProcedureCategoryOptions { get; set; } = [];
}

public class ProcedureDetailsViewModel
{
    public EMR.Web.Models.Entities.ProcedureMaster Procedure { get; set; } = null!;
    public List<EMR.Web.Models.Entities.ProcedureTariffMaster> Tariffs { get; set; } = [];
    public bool HasConfiguredTariffs => Tariffs.Count > 0;
}
