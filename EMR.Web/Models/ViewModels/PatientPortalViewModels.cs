using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class PatientLoginViewModel
{
    [Required(ErrorMessage = "Patient ID is required.")]
    [Display(Name = "Patient ID")]
    public string Username { get; set; } = string.Empty;

    [Required(ErrorMessage = "Password is required.")]
    [DataType(DataType.Password)]
    public string Password { get; set; } = string.Empty;
}

public class PatientChangePasswordViewModel
{
    public int PatientId { get; set; }

    [Required(ErrorMessage = "New Password is required.")]
    [DataType(DataType.Password)]
    [Display(Name = "New Password")]
    [StringLength(100, MinimumLength = 8, ErrorMessage = "Use at least 8 characters.")]
    [RegularExpression(@"^(?=.*[A-Za-z])(?=.*\d).+$", ErrorMessage = "Use at least one letter and one digit.")]
    public string NewPassword { get; set; } = string.Empty;

    [Required(ErrorMessage = "Confirm Password is required.")]
    [DataType(DataType.Password)]
    [Display(Name = "Confirm Password")]
    [Compare("NewPassword", ErrorMessage = "The password and confirmation password do not match.")]
    public string ConfirmPassword { get; set; } = string.Empty;
}
