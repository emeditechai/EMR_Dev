using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class BedCategoryListItemViewModel
{
    public int BedCategoryId { get; set; }
    public string? CategoryCode { get; set; }
    public string CategoryName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BedCategoryFormViewModel
{
    public int BedCategoryId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [MaxLength(50, ErrorMessage = "Code cannot exceed 50 characters.")]
    [Display(Name = "Category Code")]
    public string? CategoryCode { get; set; }

    [Required(ErrorMessage = "Bed Category Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Bed Category Name")]
    public string CategoryName { get; set; } = string.Empty;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Description / Pricing / Amenity Notes")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}

public class BedCategoryDetailsViewModel
{
    public int BedCategoryId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public string? CategoryCode { get; set; }
    public string CategoryName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}
