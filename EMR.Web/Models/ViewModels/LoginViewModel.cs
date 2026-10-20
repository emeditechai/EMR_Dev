using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class LoginViewModel
{
    /// <summary>Users sign in with their e-mail address (SQLScripts/2307).</summary>
    [Required(ErrorMessage = "Enter your e-mail address.")]
    [EmailAddress(ErrorMessage = "Enter a valid e-mail address.")]
    [Display(Name = "Email")]
    public string Email { get; set; } = string.Empty;

    [Required]
    [DataType(DataType.Password)]
    public string Password { get; set; } = string.Empty;

    public bool RememberMe { get; set; }
}
