using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class ProcedureTariffListItemViewModel
{
    public int ProcedureTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;
    public string SpecialityName { get; set; } = string.Empty;
    public decimal SurgeonFee { get; set; }
    public decimal AssistantFee { get; set; }
    public decimal AnaesthetistFee { get; set; }
    public decimal OtCharges { get; set; }
    public decimal EquipmentCharges { get; set; }
    public decimal ConsumableCharges { get; set; }
    public decimal NursingCharges { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class ProcedureTariffFormViewModel
{
    public int ProcedureTariffId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Tariff Category is required")]
    [Display(Name = "Tariff Category")]
    public int TariffCategoryId { get; set; }

    [Required(ErrorMessage = "Procedure is required")]
    [Display(Name = "Procedure")]
    public int ProcedureId { get; set; }

    [Range(0, 99999999.99, ErrorMessage = "Fee must be 0 or greater")]
    [Display(Name = "Surgeon Fee")]
    public decimal SurgeonFee { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Fee must be 0 or greater")]
    [Display(Name = "Assistant Surgeon Fee")]
    public decimal AssistantFee { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Fee must be 0 or greater")]
    [Display(Name = "Anaesthetist Fee")]
    public decimal AnaesthetistFee { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Charge must be 0 or greater")]
    [Display(Name = "OT Charges")]
    public decimal OtCharges { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Charge must be 0 or greater")]
    [Display(Name = "Equipment Charges")]
    public decimal EquipmentCharges { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Charge must be 0 or greater")]
    [Display(Name = "Consumables Charges")]
    public decimal ConsumableCharges { get; set; } = 0;

    [Range(0, 99999999.99, ErrorMessage = "Charge must be 0 or greater")]
    [Display(Name = "Nursing Charges")]
    public decimal NursingCharges { get; set; } = 0;

    [Display(Name = "Total Tariff / Rate (₹)")]
    public decimal TotalRate { get; set; } = 0;

    [Required(ErrorMessage = "Effective From Date is required")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime? EffectiveTo { get; set; }

    [StringLength(500)]
    [Display(Name = "Description / Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Is Active")]
    public bool IsActive { get; set; } = true;

    // Lock indicator when opened from Procedure Details
    public bool IsProcedureLocked { get; set; }
    public string? SelectedProcedureName { get; set; }

    // Dropdowns
    public List<SelectListItem> TariffCategoryOptions { get; set; } = [];
    public List<SelectListItem> ProcedureOptions { get; set; } = [];
}
