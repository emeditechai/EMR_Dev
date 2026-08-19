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
