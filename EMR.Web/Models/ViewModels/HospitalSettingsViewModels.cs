using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Http;

namespace EMR.Web.Models.ViewModels;

public class HospitalSettingsViewModel
{
    public int Id { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    [Display(Name = "Hospital Name")]
    [MaxLength(200)]
    public string? HospitalName { get; set; }

    [Display(Name = "Address")]
    [MaxLength(500)]
    public string? Address { get; set; }

    [Display(Name = "Contact Number 1")]
    [MaxLength(20)]
    public string? ContactNumber1 { get; set; }

    [Display(Name = "Contact Number 2")]
    [MaxLength(20)]
    public string? ContactNumber2 { get; set; }

    [Display(Name = "Email Address")]
    [EmailAddress]
    [MaxLength(150)]
    public string? EmailAddress { get; set; }

    [Display(Name = "Website")]
    [MaxLength(200)]
    public string? Website { get; set; }

    [Display(Name = "GST Code")]
    [MaxLength(50)]
    public string? GSTCode { get; set; }

    [Display(Name = "Logo Path")]
    [MaxLength(500)]
    public string? LogoPath { get; set; }

    [Display(Name = "Upload Logo")]
    public IFormFile? LogoFile { get; set; }

    [Display(Name = "Check-In Time")]
    public string? CheckInTime { get; set; }   // "HH:mm" string for HTML time input

    [Display(Name = "Check-Out Time")]
    public string? CheckOutTime { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; }
    public DateTime? LastModifiedDate { get; set; }
}
