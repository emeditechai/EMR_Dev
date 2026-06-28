using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class SmtpEmailConfiguration
{
    public int Id { get; set; }

    public int BranchId { get; set; }

    [MaxLength(100)]
    public string ConfigName { get; set; } = string.Empty;

    [MaxLength(50)]
    public string ProviderType { get; set; } = "Custom";

    [MaxLength(200)]
    public string SmtpHost { get; set; } = string.Empty;

    public int SmtpPort { get; set; } = 587;

    public bool UseSsl { get; set; } = true;

    public bool UseStartTls { get; set; } = true;

    [MaxLength(200)]
    public string SenderEmail { get; set; } = string.Empty;

    [MaxLength(200)]
    public string? SenderDisplayName { get; set; }

    [MaxLength(200)]
    public string Username { get; set; } = string.Empty;

    [MaxLength(500)]
    public string PasswordEncrypted { get; set; } = string.Empty;

    public bool IsDefault { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime? LastTestedDate { get; set; }

    [MaxLength(500)]
    public string? LastTestResult { get; set; }

    public int CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation
    public BranchMaster? Branch { get; set; }
}
