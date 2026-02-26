using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class FloorFormViewModel
{
    public int FloorId { get; set; }

    [Required(ErrorMessage = "Floor Code is required.")]
    [MaxLength(20, ErrorMessage = "Maximum 20 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-]+$", ErrorMessage = "Only letters, numbers and hyphens are allowed.")]
    [Display(Name = "Floor Code")]
    public string FloorCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Floor Name is required.")]
    [MaxLength(100, ErrorMessage = "Maximum 100 characters allowed.")]
    [Display(Name = "Floor Name")]
    public string FloorName { get; set; } = string.Empty;

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}
