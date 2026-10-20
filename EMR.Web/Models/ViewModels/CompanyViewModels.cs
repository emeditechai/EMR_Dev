using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class CompanyListItemViewModel
{
    public int CompanyId { get; set; }
    public string CompanyCode { get; set; } = string.Empty;
    public string CompanyName { get; set; } = string.Empty;
    public string? LegalName { get; set; }
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string? City { get; set; }
    public string? State { get; set; }
    public string? LogoPath { get; set; }
    public bool IsActive { get; set; }
    public int TotalBranches { get; set; }
    public int TotalUsers { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class CompanyFormViewModel
{
    public int CompanyId { get; set; }

    [Required(ErrorMessage = "Company code is required")]
    [MaxLength(50)]
    [Display(Name = "Company Code")]
    public string CompanyCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Company name is required")]
    [MaxLength(200)]
    [Display(Name = "Company Name")]
    public string CompanyName { get; set; } = string.Empty;

    [MaxLength(200)]
    [Display(Name = "Legal / Registered Name")]
    public string? LegalName { get; set; }

    [MaxLength(50)]
    [Display(Name = "Registration Number / CIN")]
    public string? RegistrationNumber { get; set; }

    [MaxLength(50)]
    [Display(Name = "GSTIN")]
    public string? GSTIN { get; set; }

    [MaxLength(50)]
    [Display(Name = "PAN Number")]
    public string? PAN { get; set; }

    [MaxLength(200)]
    [EmailAddress]
    [Display(Name = "Official Email")]
    public string? Email { get; set; }

    [MaxLength(50)]
    [Display(Name = "Contact Phone")]
    public string? Phone { get; set; }

    [MaxLength(200)]
    [Url]
    [Display(Name = "Website URL")]
    public string? Website { get; set; }

    [MaxLength(500)]
    [Display(Name = "Registered Address")]
    public string? Address { get; set; }

    [MaxLength(100)]
    public string? Country { get; set; } = "India";

    [MaxLength(100)]
    public string? State { get; set; }

    [MaxLength(100)]
    public string? City { get; set; }

    [MaxLength(20)]
    public string? Pincode { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    [Display(Name = "Company Logo")]
    public IFormFile? LogoFile { get; set; }

    public string? ExistingLogoPath { get; set; }
}

public class CompanyDetailsViewModel
{
    public int CompanyId { get; set; }
    public string CompanyCode { get; set; } = string.Empty;
    public string CompanyName { get; set; } = string.Empty;
    public string? LegalName { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? GSTIN { get; set; }
    public string? PAN { get; set; }
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string? Website { get; set; }
    public string? LogoPath { get; set; }
    public string? FullAddress { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public List<BranchSummaryItem> Branches { get; set; } = [];
    public List<UserSummaryItem> Users { get; set; } = [];
}

public class BranchSummaryItem
{
    public int BranchId { get; set; }
    public string BranchCode { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? City { get; set; }
    public string? State { get; set; }
    public bool IsHOBranch { get; set; }
    public bool IsActive { get; set; }
    public int ActiveUsersCount { get; set; }
}

public class UserSummaryItem
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public string? FullName { get; set; }
    public string? Role { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>
/// Settings > Company Master > New Company wizard (SQLScripts/2306): the company, its Head Office branch, its Hospital
/// Settings, its first Administrator and what to copy from a template company - created in one step.
/// </summary>
public class CompanyOnboardViewModel
{
    // 1. company
    [Required(ErrorMessage = "Company Code is required.")]
    [StringLength(20, ErrorMessage = "Company Code can be up to 20 characters.")]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Use letters, digits, - and _ only.")]
    [Display(Name = "Company Code")]
    public string CompanyCode { get; set; } = string.Empty;
    [Required(ErrorMessage = "Company / Brand Name is required.")]
    [StringLength(200)]
    [Display(Name = "Company / Brand Name")]
    public string CompanyName { get; set; } = string.Empty;
    [StringLength(250)] public string? LegalName { get; set; }
    [StringLength(100)] public string? RegistrationNumber { get; set; }
    [StringLength(20)] [RegularExpression(@"^[0-9A-Za-z]{15}$", ErrorMessage = "GSTIN has 15 letters / digits.")] public string? GSTIN { get; set; }
    [StringLength(10)] [RegularExpression(@"^[A-Za-z]{5}[0-9]{4}[A-Za-z]$", ErrorMessage = "PAN looks like AAACP1234A.")] public string? PAN { get; set; }
    [EmailAddress] [StringLength(200)] public string? Email { get; set; }
    [StringLength(50)] public string? Phone { get; set; }
    [StringLength(250)] public string? Website { get; set; }
    [StringLength(500)] public string? Address { get; set; }
    public string? Country { get; set; } = "India";
    public string? State { get; set; }
    public string? City { get; set; }
    [StringLength(10)] public string? Pincode { get; set; }
    public IFormFile? LogoFile { get; set; }

    // 2. head office branch (branch codes are unique in the whole application)
    [Required(ErrorMessage = "Branch Code is required.")]
    [StringLength(20)]
    [RegularExpression(@"^[A-Za-z0-9\-_]+$", ErrorMessage = "Use letters, digits, - and _ only.")]
    [Display(Name = "Branch Code")]
    public string BranchCode { get; set; } = string.Empty;
    [Required(ErrorMessage = "Branch Name is required.")]
    [StringLength(200)]
    [Display(Name = "Branch Name")]
    public string BranchName { get; set; } = "Head Office";
    public bool SameAddressAsCompany { get; set; } = true;
    [StringLength(500)] public string? BranchAddress { get; set; }
    public string? BranchState { get; set; }
    public string? BranchCity { get; set; }
    [StringLength(10)] public string? BranchPincode { get; set; }
    public bool BranchIsLab { get; set; } = true;

    // 3. hospital settings
    [Required(ErrorMessage = "Hospital name (shown on bills and reports) is required.")]
    [StringLength(200)]
    [Display(Name = "Hospital Name")]
    public string HospitalName { get; set; } = string.Empty;
    [StringLength(50)] public string? HospitalPhone { get; set; }
    [EmailAddress] [StringLength(200)] public string? HospitalEmail { get; set; }
    [Range(0, 3650, ErrorMessage = "Enter 0 - 3650 days.")]
    public int? OpdRegistrationValidityDays { get; set; }

    // 4. administrator
    [Required(ErrorMessage = "Username is required.")]
    [StringLength(100)]
    [RegularExpression(@"^[A-Za-z0-9._@\-]+$", ErrorMessage = "Use letters, digits and . _ @ - only.")]
    [Display(Name = "Username")]
    public string AdminUsername { get; set; } = string.Empty;
    [Required(ErrorMessage = "First Name is required.")] [StringLength(100)] public string AdminFirstName { get; set; } = string.Empty;
    [Required(ErrorMessage = "Last Name is required.")] [StringLength(100)] public string AdminLastName { get; set; } = string.Empty;
    [EmailAddress] [StringLength(200)] public string? AdminEmail { get; set; }
    [StringLength(20)] public string? AdminPhone { get; set; }
    [StringLength(20)] public string? AdminEmployeeCode { get; set; }
    [Required(ErrorMessage = "Password is required.")]
    [StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters.")]
    [DataType(DataType.Password)]
    public string? AdminPassword { get; set; }
    [Required(ErrorMessage = "Confirm the password.")]
    [Compare(nameof(AdminPassword), ErrorMessage = "Passwords do not match.")]
    [DataType(DataType.Password)]
    public string? AdminConfirmPassword { get; set; }
    public bool AdminMustChangePassword { get; set; } = true;

    // 5. copy from a template company
    [Range(1, int.MaxValue, ErrorMessage = "Choose the company to copy the menus from.")]
    public int TemplateCompanyId { get; set; }
    public bool CopyAdminPermissions { get; set; } = true;
    public bool CopyOtherRoles { get; set; } = true;

    public List<EMR.Web.ApiClients.CompanyOnboardTemplate> Templates { get; set; } = new();
    /// <summary>The step to open (the first one with an error after a failed save).</summary>
    public int Step { get; set; } = 1;
}
