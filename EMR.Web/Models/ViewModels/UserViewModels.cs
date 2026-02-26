using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class UserListItemViewModel
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string EmployeeCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public string Branches { get; set; } = string.Empty;
}

public class UserFormViewModel
{
    public int Id { get; set; }

    [MaxLength(50)]
    [Display(Name = "Employee Code")]
    public string? EmployeeCode { get; set; }

    [Required]
    [MaxLength(100)]
    public string Username { get; set; } = string.Empty;

    [EmailAddress]
    [MaxLength(200)]
    public string? Email { get; set; }

    [Display(Name = "Password")]
    [DataType(DataType.Password)]
    public string? Password { get; set; }

    [Display(Name = "Confirm Password")]
    [DataType(DataType.Password)]
    [Compare(nameof(Password), ErrorMessage = "Passwords do not match.")]
    public string? ConfirmPassword { get; set; }

    [Required]
    [MaxLength(100)]
    [Display(Name = "First Name")]
    public string FirstName { get; set; } = string.Empty;

    [Required]
    [MaxLength(100)]
    [Display(Name = "Last Name")]
    public string LastName { get; set; } = string.Empty;

    [Phone]
    [Display(Name = "Phone Number")]
    public string? PhoneNumber { get; set; }

    [Display(Name = "Profile Picture")]
    public IFormFile? ProfilePictureFile { get; set; }

    public string? ExistingProfilePicturePath { get; set; }

    public bool IsActive { get; set; } = true;

    public List<int> SelectedBranchIds { get; set; } = new();
    public List<int> SelectedRoleIds { get; set; } = new();

    public List<SelectListItem> BranchOptions { get; set; } = new();
    public List<BranchRoleGroup> BranchRoleGroups { get; set; } = new();
}

public class BranchRoleGroup
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public List<RoleItem> Roles { get; set; } = new();
}

public class RoleItem
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class UserDetailsViewModel
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string EmployeeCode { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string FirstName { get; set; } = string.Empty;
    public string LastName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public bool IsActive { get; set; }
    public bool IsLockedOut { get; set; }
    public DateTime? LastLoginDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? LastModifiedDate { get; set; }
    public string? ProfilePicturePath { get; set; }
    public List<string> Branches { get; set; } = new();
    public List<BranchRoleDetailItem> BranchRoleMappings { get; set; } = new();
}

public class BranchRoleDetailItem
{
    public string BranchName { get; set; } = string.Empty;
    public string? EmployeeCode { get; set; }
    public List<string> Roles { get; set; } = new();
}
