using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class GovernmentSchemeListItemViewModel
{
    public int Scheme_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string SchemeCode { get; set; } = string.Empty;
    public string SchemeName { get; set; } = string.Empty;
    public string SchemeType { get; set; } = string.Empty; // Central Government, State Government, Defence / Ex-Servicemen, PSU / Autonomous Body, Social Security / Labour
    public string AuthorityName { get; set; } = string.Empty;
    public string? RuleConfigJSON { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public SchemeRuleConfigModel? ParsedRuleConfig
    {
        get
        {
            if (string.IsNullOrWhiteSpace(RuleConfigJSON)) return null;
            try
            {
                return JsonSerializer.Deserialize<SchemeRuleConfigModel>(RuleConfigJSON, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            }
            catch
            {
                return null;
            }
        }
    }
}

public class GovernmentSchemeIndexViewModel
{
    public List<GovernmentSchemeListItemViewModel> SchemeList { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public string? SelectedSchemeType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> SchemeTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
}

public class GovernmentSchemeFormViewModel
{
    public int Scheme_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Scheme Code is mandatory.")]
    [StringLength(50, ErrorMessage = "Scheme Code cannot exceed 50 characters.")]
    [Display(Name = "Scheme Code")]
    public string SchemeCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Scheme Name is mandatory.")]
    [StringLength(200, ErrorMessage = "Scheme Name cannot exceed 200 characters.")]
    [Display(Name = "Scheme Name")]
    public string SchemeName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Scheme Type is mandatory.")]
    [StringLength(100)]
    [Display(Name = "Scheme Type")]
    public string SchemeType { get; set; } = "Central Government";

    [Required(ErrorMessage = "Authority / Ministry Name is mandatory.")]
    [StringLength(200, ErrorMessage = "Authority Name cannot exceed 200 characters.")]
    [Display(Name = "Nodal Authority / Ministry Name")]
    public string AuthorityName { get; set; } = string.Empty;

    [Display(Name = "Scheme Rules Configuration (JSON)")]
    public string? RuleConfigJSON { get; set; }

    [Required(ErrorMessage = "Effective From date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [Required(ErrorMessage = "Effective To date is mandatory.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime Effective_To { get; set; } = DateTime.Today.AddYears(5);

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Visual Form Helper Fields for Indian Government Health Standard Configuration
    [Display(Name = "Annual Family Coverage Limit (₹)")]
    public decimal AnnualCoverageLimit { get; set; } = 500000;

    [Display(Name = "Pre-Authorization Mandatory")]
    public bool PreAuthMandatory { get; set; } = true;

    [Display(Name = "Aadhaar / ABHA Biometric Authentication Required")]
    public bool BiometricAuthRequired { get; set; } = true;

    [Display(Name = "Mandatory ABHA ID Creation & Linking")]
    public bool AbhaCreationMandatory { get; set; } = true;

    [Display(Name = "Patient Co-Pay Percentage (%)")]
    public decimal CoPayPercentage { get; set; } = 0;

    [Display(Name = "Max Claim Submission Window (Days)")]
    public int MaxClaimSubmissionDays { get; set; } = 7;

    [Display(Name = "Package Rate Discount (%)")]
    public decimal PackageRateDiscountPercent { get; set; } = 0;

    [Display(Name = "Default Bed Category Entitlement")]
    public string DefaultBedCategory { get; set; } = "General Ward";

    [Display(Name = "TMS / Portal URL")]
    public string? TMSPortalUrl { get; set; } = "https://tms.pmjay.gov.in";

    [Display(Name = "NHA / SHA Agency Code")]
    public string? NHA_SchemeCode { get; set; } = "PMJAY_V2";

    [Display(Name = "Primary Beneficiary ID Type")]
    public string BeneficiaryIdType { get; set; } = "PM-JAY Golden Card / Aadhaar / Ration Card";

    [Display(Name = "Special Guidelines / Remarks")]
    public string? SpecialRemarks { get; set; }

    public List<SelectListItem> SchemeTypeOptions { get; set; } = [];
}

public class SchemeRuleConfigModel
{
    public decimal AnnualCoverageLimit { get; set; }
    public bool PreAuthMandatory { get; set; }
    public bool BiometricAuthRequired { get; set; }
    public bool AbhaCreationMandatory { get; set; }
    public decimal CoPayPercentage { get; set; }
    public int MaxClaimSubmissionDays { get; set; }
    public decimal PackageRateDiscountPercent { get; set; }
    public string? DefaultBedCategory { get; set; }
    public string? TMSPortalUrl { get; set; }
    public string? NHA_SchemeCode { get; set; }
    public string? BeneficiaryIdType { get; set; }
    public List<string> MandatoryDocuments { get; set; } = [];
    public string? SpecialRemarks { get; set; }
}
