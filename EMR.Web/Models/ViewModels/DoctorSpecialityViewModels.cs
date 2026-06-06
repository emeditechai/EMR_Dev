using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class DoctorSpecialityFormViewModel
{
    public int SpecialityId { get; set; }

    [Required(ErrorMessage = "Speciality Code is required.")]
    [MaxLength(50, ErrorMessage = "Maximum 50 characters allowed.")]
    [Display(Name = "Speciality Code")]
    public string SpecialityCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Speciality Name is required.")]
    [MaxLength(100, ErrorMessage = "Maximum 100 characters allowed.")]
    [Display(Name = "Speciality Name")]
    public string SpecialityName { get; set; } = string.Empty;

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}
