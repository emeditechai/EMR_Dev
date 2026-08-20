using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class AnaesthesiaTypeListItemViewModel
{
    public int AnaesthesiaTypeId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public string TypeCode { get; set; } = string.Empty;
    public string TypeName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int TotalRatesConfigured { get; set; }
}

public class AnaesthesiaTypeFormViewModel
{
    public int AnaesthesiaTypeId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Type Code is required")]
    [StringLength(50, ErrorMessage = "Type Code cannot exceed 50 characters")]
    [Display(Name = "Anaesthesia Type Code")]
    public string TypeCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Type Name is required")]
    [StringLength(100, ErrorMessage = "Type Name cannot exceed 100 characters")]
    [Display(Name = "Anaesthesia Type Name")]
    public string TypeName { get; set; } = string.Empty;

    [StringLength(500)]
    [Display(Name = "Description / Clinical Indications")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;
}

public class AnaesthesiaRateListItemViewModel
{
    public int AnaesthesiaRateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public string? DepartmentName { get; set; }
    public int AnaesthesiaTypeId { get; set; }
    public string AnaesthesiaTypeCode { get; set; } = string.Empty;
    public string AnaesthesiaTypeName { get; set; } = string.Empty;
    public decimal AnaesthetistFee { get; set; }
    public decimal ConsumableCharge { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class AnaesthesiaRateFormViewModel
{
    public int AnaesthesiaRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Procedure is required")]
    [Display(Name = "Surgical / Clinical Procedure")]
    public int ProcedureId { get; set; }

    [Required(ErrorMessage = "Anaesthesia Type is required")]
    [Display(Name = "Anaesthesia Type")]
    public int AnaesthesiaTypeId { get; set; }

    [Required(ErrorMessage = "Anaesthetist Fee is required")]
    [Display(Name = "Anaesthetist Professional Fee")]
    [Range(0, 10000000, ErrorMessage = "Fee must be a valid positive amount")]
    public decimal AnaesthetistFee { get; set; } = 0;

    [Required(ErrorMessage = "Consumable Charge is required")]
    [Display(Name = "Anaesthesia Consumables & Gases Charge")]
    [Range(0, 10000000, ErrorMessage = "Charge must be a valid positive amount")]
    public decimal ConsumableCharge { get; set; } = 0;

    [Display(Name = "Total Anaesthesia Rate")]
    public decimal TotalRate { get; set; }

    [Required(ErrorMessage = "Effective From date is required")]
    [Display(Name = "Effective From")]
    [DataType(DataType.Date)]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [Display(Name = "Effective To")]
    [DataType(DataType.Date)]
    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    [Display(Name = "Description / Package Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dropdowns
    public List<SelectListItem> ProcedureOptions { get; set; } = [];
    public List<SelectListItem> AnaesthesiaTypeOptions { get; set; } = [];
}

public class AnaesthesiaUnifiedViewModel
{
    public List<AnaesthesiaRateListItemViewModel> Rates { get; set; } = [];
    public List<AnaesthesiaTypeListItemViewModel> Types { get; set; } = [];

    public int? SelectedProcedureId { get; set; }
    public int? SelectedAnaesthesiaTypeId { get; set; }
    public string ActiveTab { get; set; } = "rates"; // "rates" or "types"

    public List<SelectListItem> ProcedureOptions { get; set; } = [];
    public List<SelectListItem> AnaesthesiaTypeOptions { get; set; } = [];

    // KPI Summary
    public int TotalTypesCount => Types.Count;
    public int ActiveTypesCount => Types.Count(t => t.IsActive);
    public int TotalRatesCount => Rates.Count;
    public int ActiveRatesCount => Rates.Count(r => r.IsActive);
}
