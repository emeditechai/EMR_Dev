using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorIpIndexViewModel
{
    public List<DoctorIpListModel> Items { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public string? BranchName { get; set; }
    public int UnlockMinutesLeft { get; set; }
    public bool IsSuperAdmin { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
}

public class DoctorIpFormViewModel
{
    public int Doctor_IP_Hdr_ID { get; set; }

    [Required(ErrorMessage = "Speciality is required.")]
    [Range(1, int.MaxValue, ErrorMessage = "Speciality is required.")]
    [Display(Name = "Speciality")]
    public int Speciality_ID { get; set; }

    [Required(ErrorMessage = "Doctor is required.")]
    [Range(1, int.MaxValue, ErrorMessage = "Doctor is required.")]
    [Display(Name = "Referral Doctor")]
    public int Doctor_ID { get; set; }

    public int Branch_ID { get; set; }
    public string? Branch_Name { get; set; }

    [Required(ErrorMessage = "Effective From is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime Effective_From { get; set; } = DateTime.Today;

    [Required(ErrorMessage = "Effective To is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime Effective_To { get; set; } = new DateTime(DateTime.Today.Year, 12, 31);

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    /// <summary>Grid rows as JSON: [{Test_ID, Commission_Rate, ...display fields}].</summary>
    public string DetailsJson { get; set; } = "[]";

    public string? CopiedFrom { get; set; }

    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> CopySourceOptions { get; set; } = [];
}

public class DoctorIpUnlockViewModel
{
    [Required(ErrorMessage = "Enter the access code.")]
    [DataType(DataType.Password)]
    [Display(Name = "Access Code")]
    public string Code { get; set; } = string.Empty;

    public string? ReturnUrl { get; set; }
    public bool IsConfigured { get; set; }
    public bool IsLockedOut { get; set; }
    public int LockedMinutesLeft { get; set; }
    public int AttemptsLeft { get; set; }
    public bool IsSuperAdmin { get; set; }
}

public class DoctorIpSetCodeViewModel
{
    public bool IsConfigured { get; set; }

    [DataType(DataType.Password)]
    [Display(Name = "Current Access Code")]
    public string? CurrentCode { get; set; }

    [Required(ErrorMessage = "Enter the new access code.")]
    [StringLength(100, MinimumLength = 6, ErrorMessage = "The access code must be at least 6 characters.")]
    [DataType(DataType.Password)]
    [Display(Name = "New Access Code")]
    public string NewCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Confirm the new access code.")]
    [Compare(nameof(NewCode), ErrorMessage = "The codes do not match.")]
    [DataType(DataType.Password)]
    [Display(Name = "Confirm New Access Code")]
    public string ConfirmCode { get; set; } = string.Empty;
}
