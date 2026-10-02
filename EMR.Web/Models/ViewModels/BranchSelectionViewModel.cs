using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class BranchSelectionViewModel
{
    [Required]
    [Display(Name = "Available Branches")]
    public int BranchId { get; set; }

    public string DisplayName { get; set; } = string.Empty;
    public List<SelectListItem> Branches { get; set; } = new();

    /// <summary>Switch Branch from the profile menu (already signed in) rather than the branch step of sign-in.</summary>
    public bool IsSwitch { get; set; }
    public string? CurrentBranchName { get; set; }
}
