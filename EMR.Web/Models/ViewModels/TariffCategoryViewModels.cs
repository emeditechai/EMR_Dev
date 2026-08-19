using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class TariffCategoryListItemViewModel
{
    public int TariffCategoryId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string PatientCategory { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class TariffCategoryFormViewModel
{
    public int TariffCategoryId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required(ErrorMessage = "Category Code is required.")]
    [MaxLength(10, ErrorMessage = "Code cannot exceed 10 characters.")]
    [Display(Name = "Tariff Code")]
    public string Code { get; set; } = string.Empty;

    [Required(ErrorMessage = "Tariff Category Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Tariff Category Name")]
    public string Name { get; set; } = string.Empty;

    [Required(ErrorMessage = "Patient Category is required.")]
    [MaxLength(100, ErrorMessage = "Maximum 100 characters allowed.")]
    [Display(Name = "Patient Category")]
    public string PatientCategory { get; set; } = "Cash / Self Pay";

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Contract Terms")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public IEnumerable<SelectListItem> PatientCategoryOptions { get; set; } = new List<SelectListItem>();
}

public class TariffCategoryDetailsViewModel
{
    public int TariffCategoryId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string PatientCategory { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}
