using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class DepartmentFormViewModel
{
    public int DeptId { get; set; }

    [Required(ErrorMessage = "Department Code is required.")]
    [MaxLength(20, ErrorMessage = "Maximum 20 characters allowed.")]
    [RegularExpression(@"^[A-Za-z0-9\-]+$", ErrorMessage = "Only letters, numbers and hyphens are allowed.")]
    [Display(Name = "Dept Code")]
    public string DeptCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Department Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Dept Name")]
    public string DeptName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Department Type is required.")]
    [Display(Name = "Type")]
    public string DeptType { get; set; } = string.Empty;

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}
