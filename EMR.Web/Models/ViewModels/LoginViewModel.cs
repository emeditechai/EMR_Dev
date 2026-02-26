using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

public class LoginViewModel
{
    [Required]
    [Display(Name = "User Name")]
    public string Username { get; set; } = string.Empty;

    [Required]
    [DataType(DataType.Password)]
    public string Password { get; set; } = string.Empty;

    public bool RememberMe { get; set; }
}
