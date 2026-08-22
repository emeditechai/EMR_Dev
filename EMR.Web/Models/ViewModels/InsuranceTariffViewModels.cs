using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class InsuranceTariffListItemViewModel
{
    public int InsTariff_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int InsuranceTPA_ID { get; set; }
    public string InsuranceTPAName { get; set; } = string.Empty;
    public string? InsuranceTPACode { get; set; }
    public string? InsuranceTPAType { get; set; }
    public string EntitlementType { get; set; } = string.Empty; // Room, Package, Procedure, HospitalService, NonPayableItem
    public int Reference_ID { get; set; }
    public string DeductionRuleType { get; set; } = "None"; // None, Fixed Deduction, Percentage Co-Pay, Proportional Capping, Non-Payable Item, Agreed Tariff Cap
    public decimal DeductionValue { get; set; }
    public decimal Rate { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Resolved dynamic master values
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }
    public decimal StandardBaseRate { get; set; }
}

public class InsuranceTariffFormViewModel
{
    public int InsTariff_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Insurance / TPA Partner is mandatory.")]
    [Display(Name = "Insurance / TPA Partner")]
    public int InsuranceTPA_ID { get; set; }

    public string? InsuranceTPAName { get; set; }

    [Required(ErrorMessage = "Entitlement Type is mandatory.")]
    [Display(Name = "Entitlement Type (Head)")]
    public string EntitlementType { get; set; } = "Procedure"; // Room, Package, Procedure, HospitalService, NonPayableItem

    [Required(ErrorMessage = "Reference Master Service item is mandatory.")]
    [Display(Name = "Master Service Item")]
    public int Reference_ID { get; set; }

    [Required(ErrorMessage = "Deduction Rule Type is mandatory.")]
    [Display(Name = "Deduction / Tariff Rule")]
    public string DeductionRuleType { get; set; } = "Standard Tariff";

    [Range(0, 999999999.99, ErrorMessage = "Deduction value must be positive.")]
    [Display(Name = "Deduction / Co-Pay Value")]
    public decimal DeductionValue { get; set; } = 0;

    [Range(0, 999999999.99, ErrorMessage = "Tariff Rate must be positive.")]
    [Display(Name = "Agreed Insurer Tariff Rate (₹)")]
    public decimal Rate { get; set; } = 0;

    [Required(ErrorMessage = "Effective From date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [Required(ErrorMessage = "Effective To date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime Effective_To { get; set; } = DateTime.Today.AddYears(1);

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown helpers
    public List<SelectListItem> EntitlementTypeOptions { get; set; } = [];
    public List<SelectListItem> DeductionRuleTypeOptions { get; set; } = [];
    public List<SelectListItem> MasterItemOptions { get; set; } = [];
}

public class InsuranceMasterServiceItemViewModel
{
    public string EntitlementType { get; set; } = string.Empty;
    public int Reference_ID { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal BaseRate { get; set; }
}

public class InsuranceTariffsModalViewModel
{
    public int InsuranceTPA_ID { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Code { get; set; }
    public string? Type { get; set; }
    public string? PolicyPrefix { get; set; }
    public List<InsuranceTariffListItemViewModel> Tariffs { get; set; } = [];
}
