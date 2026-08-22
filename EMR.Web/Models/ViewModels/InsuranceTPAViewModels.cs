using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class InsuranceTPAListItemViewModel
{
    public int InsuranceTPA_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Type { get; set; } = string.Empty; // 'Insurance Company', 'TPA'
    public string Name { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public string? SchemeName { get; set; }
    public string PolicyPrefix { get; set; } = string.Empty;
    public string NetworkCategory { get; set; } = string.Empty; // 'Cashless', 'Reimbursement', 'Both'
    public bool AuthorizationRequired { get; set; }
    public string? ContactPerson { get; set; }
    public string? ContactNumber { get; set; }
    public string? Email { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public int TariffsCount { get; set; }
    public List<InsuranceTariffListItemViewModel> Tariffs { get; set; } = [];
}

public class InsuranceTPAIndexViewModel
{
    public List<InsuranceTPAListItemViewModel> InsuranceList { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public string? SelectedType { get; set; }
    public string? SelectedNetworkCategory { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> TypeOptions { get; set; } = [];
    public List<SelectListItem> NetworkCategoryOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
}

public class InsuranceTPAFormViewModel
{
    public int InsuranceTPA_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Type is mandatory.")]
    [Display(Name = "Type")]
    public string Type { get; set; } = "Insurance Company"; // Insurance Company / TPA

    [Required(ErrorMessage = "Name is mandatory.")]
    [StringLength(200, ErrorMessage = "Name cannot exceed 200 characters.")]
    [Display(Name = "Insurance / TPA Name")]
    public string Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Code is mandatory.")]
    [StringLength(50, ErrorMessage = "Code cannot exceed 50 characters.")]
    [Display(Name = "Code")]
    public string Code { get; set; } = string.Empty;

    [StringLength(200, ErrorMessage = "Scheme Name cannot exceed 200 characters.")]
    [Display(Name = "Scheme Name")]
    public string? SchemeName { get; set; }

    [Required(ErrorMessage = "Policy Prefix is mandatory.")]
    [StringLength(50, ErrorMessage = "Policy Prefix cannot exceed 50 characters.")]
    [Display(Name = "Policy Prefix")]
    public string PolicyPrefix { get; set; } = string.Empty;

    [Required(ErrorMessage = "Network Category is mandatory.")]
    [Display(Name = "Network Category")]
    public string NetworkCategory { get; set; } = "Both"; // Cashless / Reimbursement / Both

    [Display(Name = "Authorization Required")]
    public bool AuthorizationRequired { get; set; } = true;

    [StringLength(150, ErrorMessage = "Contact Person name cannot exceed 150 characters.")]
    [Display(Name = "Contact Person")]
    public string? ContactPerson { get; set; }

    [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Please enter a valid 10-digit mobile number (e.g. 9876543210).")]
    [Display(Name = "Contact Number")]
    public string? ContactNumber { get; set; }

    [EmailAddress(ErrorMessage = "Please enter a valid email address.")]
    [MaxLength(150)]
    [Display(Name = "Email Address")]
    public string? Email { get; set; }

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    // Dropdown helpers
    public List<SelectListItem> TypeOptions { get; set; } = [];
    public List<SelectListItem> NetworkCategoryOptions { get; set; } = [];
}
