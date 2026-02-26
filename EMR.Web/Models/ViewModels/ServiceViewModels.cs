using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class ServiceFormViewModel
{
    public int ServiceId { get; set; }

    [Required(ErrorMessage = "Item Code is required.")]
    [MaxLength(20, ErrorMessage = "Maximum 20 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-]+$", ErrorMessage = "Only letters, numbers and hyphens are allowed.")]
    [Display(Name = "Item Code")]
    public string ItemCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Item Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Item Name")]
    public string ItemName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Service Type is required.")]
    [Display(Name = "Service Type")]
    public string ServiceType { get; set; } = string.Empty;

    [Range(0, double.MaxValue, ErrorMessage = "Item Charges must be zero or greater.")]
    [Display(Name = "Item Charges")]
    public decimal ItemCharges { get; set; } = 0;

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}
