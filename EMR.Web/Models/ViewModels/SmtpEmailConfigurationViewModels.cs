using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

/// <summary>Form model for creating/editing SMTP configurations.</summary>
public class SmtpConfigFormViewModel
{
    public int Id { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Configuration name is required.")]
    [MaxLength(100)]
    [Display(Name = "Configuration Name")]
    public string ConfigName { get; set; } = string.Empty;

    [Required]
    [MaxLength(50)]
    [Display(Name = "Provider")]
    public string ProviderType { get; set; } = "Custom";

    [Required(ErrorMessage = "SMTP Host is required.")]
    [MaxLength(200)]
    [Display(Name = "SMTP Host")]
    public string SmtpHost { get; set; } = string.Empty;

    [Required]
    [Range(1, 65535, ErrorMessage = "Port must be between 1 and 65535.")]
    [Display(Name = "SMTP Port")]
    public int SmtpPort { get; set; } = 587;

    [Display(Name = "Enable SSL")]
    public bool UseSsl { get; set; } = true;

    [Display(Name = "Enable STARTTLS")]
    public bool UseStartTls { get; set; } = true;

    [Required(ErrorMessage = "Sender email is required.")]
    [EmailAddress(ErrorMessage = "Please enter a valid email address.")]
    [MaxLength(200)]
    [Display(Name = "Sender Email")]
    public string SenderEmail { get; set; } = string.Empty;

    [MaxLength(200)]
    [Display(Name = "Sender Display Name")]
    public string? SenderDisplayName { get; set; }

    [Required(ErrorMessage = "Username is required.")]
    [MaxLength(200)]
    [Display(Name = "Username")]
    public string Username { get; set; } = string.Empty;

    /// <summary>Plain text password — encrypted before DB storage. Blank on edit = keep existing.</summary>
    [MaxLength(200)]
    [Display(Name = "Password")]
    public string? Password { get; set; }

    [Display(Name = "Set as Default")]
    public bool IsDefault { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    /// <summary>True when editing (hides required on password).</summary>
    public bool IsEdit { get; set; }
}

/// <summary>List item for the Index page table.</summary>
public class SmtpConfigListItem
{
    public int Id { get; set; }
    public string ConfigName { get; set; } = string.Empty;
    public string ProviderType { get; set; } = "Custom";
    public string SmtpHost { get; set; } = string.Empty;
    public int SmtpPort { get; set; }
    public bool UseSsl { get; set; }
    public bool UseStartTls { get; set; }
    public string SenderEmail { get; set; } = string.Empty;
    public string? SenderDisplayName { get; set; }
    public bool IsDefault { get; set; }
    public bool IsActive { get; set; }
    public DateTime? LastTestedDate { get; set; }
    public string? LastTestResult { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

/// <summary>Model for the "Send Test Email" AJAX form.</summary>
public class SmtpTestEmailViewModel
{
    [Required]
    public int ConfigId { get; set; }

    [Required(ErrorMessage = "Recipient email is required.")]
    [EmailAddress(ErrorMessage = "Please enter a valid email address.")]
    [Display(Name = "Recipient Email")]
    public string RecipientEmail { get; set; } = string.Empty;

    [MaxLength(200)]
    [Display(Name = "Subject")]
    public string Subject { get; set; } = "Test Email from eClinicPlus+";

    [MaxLength(2000)]
    [Display(Name = "Body")]
    public string Body { get; set; } = "This is a test email sent from eClinicPlus+ SMTP Configuration. If you received this, your email setup is working correctly!";
}
