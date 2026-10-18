using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

/// <summary>Profile menu > Change Password: the signed-in user changes their own password.</summary>
public class ChangePasswordViewModel
{
    public const int MinLength = 8;

    [Required(ErrorMessage = "Enter your current password.")]
    [DataType(DataType.Password)]
    [Display(Name = "Current password")]
    public string CurrentPassword { get; set; } = string.Empty;

    [Required(ErrorMessage = "Enter a new password.")]
    [DataType(DataType.Password)]
    [StringLength(128, MinimumLength = MinLength, ErrorMessage = "The new password must be at least {2} characters.")]
    [RegularExpression(@"^(?=.*[A-Za-z])(?=.*\d).+$", ErrorMessage = "Use at least one letter and one number.")]
    [Display(Name = "New password")]
    public string NewPassword { get; set; } = string.Empty;

    [Required(ErrorMessage = "Type the new password again.")]
    [DataType(DataType.Password)]
    [Compare(nameof(NewPassword), ErrorMessage = "The two new passwords do not match.")]
    [Display(Name = "Confirm new password")]
    public string ConfirmPassword { get; set; } = string.Empty;

    public DateTime? PasswordLastChanged { get; set; }
}

/// <summary>Login > "Forgot password?": the user name or email of the account to reset.</summary>
public class ForgotPasswordViewModel
{
    [Required(ErrorMessage = "Enter your user name or email address.")]
    [StringLength(256)]
    [Display(Name = "User name or email")]
    public string UserNameOrEmail { get; set; } = string.Empty;
}

/// <summary>The page the emailed reset link opens: the new password, same rules as Change Password.</summary>
public class ResetPasswordViewModel
{
    [Required]
    public string Token { get; set; } = string.Empty;

    public string? UserName { get; set; }

    [Required(ErrorMessage = "Enter a new password.")]
    [DataType(DataType.Password)]
    [StringLength(128, MinimumLength = ChangePasswordViewModel.MinLength, ErrorMessage = "The new password must be at least {2} characters.")]
    [RegularExpression(@"^(?=.*[A-Za-z])(?=.*\d).+$", ErrorMessage = "Use at least one letter and one number.")]
    [Display(Name = "New password")]
    public string NewPassword { get; set; } = string.Empty;

    [Required(ErrorMessage = "Type the new password again.")]
    [DataType(DataType.Password)]
    [Compare(nameof(NewPassword), ErrorMessage = "The two passwords do not match.")]
    [Display(Name = "Confirm new password")]
    public string ConfirmPassword { get; set; } = string.Empty;
}
