using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Models.ViewModels;

public class DiscountTypeListItemViewModel
{
    public int DiscountTypeId { get; set; }
    public string DiscountTypeName { get; set; } = null!;
    public char DiscountFlag { get; set; } = 'P';
    public decimal? PercentageFrom { get; set; }
    public decimal? PercentageTo { get; set; }
    public decimal? DiscountAmount { get; set; }
    public bool IsActive { get; set; }
}

public class DiscountTypeIndexViewModel
{
    public List<DiscountTypeListItemViewModel> DiscountTypes { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
}

public class DiscountTypeFormViewModel
{
    public int DiscountTypeId { get; set; }

    [Required(ErrorMessage = "Discount Type Name is required.")]
    [StringLength(100, ErrorMessage = "Discount Type Name cannot exceed 100 characters.")]
    [Remote(action: "VerifyName", controller: "DiscountTypes", AdditionalFields = "DiscountTypeId", ErrorMessage = "A discount type with this name already exists.")]
    [Display(Name = "Discount Type Name")]
    public string DiscountTypeName { get; set; } = null!;

    [Display(Name = "Discount Type (Percentage/Amount)")]
    public char DiscountFlag { get; set; } = 'P'; // P or A

    [Range(0, 100, ErrorMessage = "From Percentage must be between 0 and 100.")]
    [Display(Name = "From Percentage (%)")]
    public decimal? PercentageFrom { get; set; }

    [Range(0, 100, ErrorMessage = "To Percentage must be between 0 and 100.")]
    [Display(Name = "To Percentage (%)")]
    public decimal? PercentageTo { get; set; }

    [Range(0, 9999999.99, ErrorMessage = "Invalid amount.")]
    [Display(Name = "Discount Amount")]
    public decimal? DiscountAmount { get; set; }

    [Display(Name = "Is Active?")]
    public bool IsActive { get; set; } = true;
}
