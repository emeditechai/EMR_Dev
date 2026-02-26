using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class BranchFormViewModel
{
    public int BranchId { get; set; }

    [Required]
    [Display(Name = "Branch Name")]
    [MaxLength(150)]
    public string BranchName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Branch Code")]
    [MaxLength(50)]
    public string BranchCode { get; set; } = string.Empty;

    [MaxLength(100)]
    public string? Country { get; set; }

    [MaxLength(100)]
    public string? State { get; set; }

    [MaxLength(100)]
    public string? City { get; set; }

    [MaxLength(250)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? Pincode { get; set; }

    [Display(Name = "Head Office Branch")]
    public bool IsHOBranch { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}

public class AccessListItemViewModel
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string BranchRoleSummary { get; set; } = string.Empty;
}

public class RoleOptionViewModel
{
    public int RoleId { get; set; }
    public string RoleName { get; set; } = string.Empty;
    public bool IsSelected { get; set; }
}

public class UserRoleAssignmentViewModel
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Branch")]
    public int BranchId { get; set; }

    public List<SelectListItem> UserBranchOptions { get; set; } = new();
    public List<RoleOptionViewModel> RoleOptions { get; set; } = new();
    public List<int> SelectedRoleIds { get; set; } = new();
}

public class RoleSelectionViewModel
{
    public string DisplayName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? ProfilePicturePath { get; set; }
    public bool RememberMe { get; set; }
    public List<RoleCardItem> Roles { get; set; } = new();
}

public class RoleCardItem
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Icon { get; set; } = string.Empty;
}

public class BranchDetailsViewModel
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string BranchCode { get; set; } = string.Empty;
    public string? Country { get; set; }
    public string? State { get; set; }
    public string? City { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public bool IsHOBranch { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int MappedUsersCount { get; set; }
    public List<string> MappedUsers { get; set; } = new();
    public List<string> Roles { get; set; } = new();
}
