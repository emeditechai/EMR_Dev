using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class PatientLoginViewModel
{
    [Required(ErrorMessage = "Username is required.")]
    [Display(Name = "Username (Patient Code)")]
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
    public string NewPassword { get; set; } = string.Empty;

    [Required(ErrorMessage = "Confirm Password is required.")]
    [DataType(DataType.Password)]
    [Display(Name = "Confirm Password")]
    [Compare("NewPassword", ErrorMessage = "The password and confirmation password do not match.")]
    public string ConfirmPassword { get; set; } = string.Empty;
}
