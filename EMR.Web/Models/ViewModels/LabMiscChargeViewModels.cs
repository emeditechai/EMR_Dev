using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public static class LabMiscChargeTypes
{
    public const string HomeCollection = "Home Collection";
    public const string Misc = "Misc";
    public static readonly string[] All = [HomeCollection, Misc];
}

public class LabMiscChargeIndexViewModel
{
    public List<LabMiscChargeModel> Charges { get; set; } = [];
    public string? SelectedChargeType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> ChargeTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabMiscChargeFormViewModel : IValidatableObject
{
    public int Misc_Charge_ID { get; set; }

    [Required(ErrorMessage = "Charge Name is required.")]
    [StringLength(150, ErrorMessage = "Charge Name cannot exceed 150 characters.")]
    [Display(Name = "Charge Name")]
    public string Charge_Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Choose the Charge Type.")]
    [Display(Name = "Charge Type")]
    public string Charge_Type { get; set; } = LabMiscChargeTypes.Misc;

    [Required(ErrorMessage = "Amount is required.")]
    [Range(typeof(decimal), "0", "99999999.99", ErrorMessage = "Amount must be 0 or more.")]
    [Display(Name = "Amount (₹)")]
    public decimal? Amount { get; set; }

    [Display(Name = "Is Discountable")]
    public bool Is_Discountable { get; set; }

    [Display(Name = "Is GST Required")]
    public bool Is_GST_Required { get; set; }

    [Range(typeof(decimal), "0.01", "28", ErrorMessage = "GST percentage must be more than 0 and at most 28.")]
    [Display(Name = "GST Percentage")]
    public decimal? GST_Percentage { get; set; }

    [StringLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Required(ErrorMessage = "Display Order is required.")]
    [Range(1, 99999, ErrorMessage = "Display Order must be between 1 and 99999.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> ChargeTypeOptions { get; set; } = [];

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (!LabMiscChargeTypes.All.Contains(Charge_Type))
            yield return new ValidationResult("Choose the Charge Type: Home Collection or Misc.", [nameof(Charge_Type)]);
        if (Is_GST_Required && (GST_Percentage is null or <= 0))
            yield return new ValidationResult("GST percentage is required when GST is applicable.", [nameof(GST_Percentage)]);
    }
}
