using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorFormViewModel
{
    public int DoctorId { get; set; }

    [Required(ErrorMessage = "Prefix is required.")]
    [MaxLength(20)]
    [Display(Name = "Prefix")]
    public string NamePrefix { get; set; } = "Dr.";

    public List<SelectListItem> PrefixOptions { get; set; } = new()
    {
        new() { Value = "Dr.", Text = "Dr." },
        new() { Value = "Prof.", Text = "Prof." },
        new() { Value = "Mr.", Text = "Mr." },
        new() { Value = "Ms.", Text = "Ms." }
    };

    [Required(ErrorMessage = "Doctor Name is required.")]
    [MaxLength(150, ErrorMessage = "Maximum 150 characters allowed.")]
    [Display(Name = "Doctor Name")]
    public string FullName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Gender is required.")]
    [Display(Name = "Gender")]
    public string Gender { get; set; } = string.Empty;

    [DataType(DataType.Date)]
    [Display(Name = "Date of Birth")]
    public DateTime? DateOfBirth { get; set; }

    [Required(ErrorMessage = "Email ID is required.")]
    [EmailAddress(ErrorMessage = "Enter a valid email address.")]
    [MaxLength(150)]
    [Display(Name = "Email ID")]
    public string EmailId { get; set; } = string.Empty;

    [Required(ErrorMessage = "Phone Number is required.")]
    [RegularExpression(@"^[0-9+\-() ]{8,20}$", ErrorMessage = "Enter a valid phone number.")]
    [Display(Name = "Phone Number")]
    public string PhoneNumber { get; set; } = string.Empty;

    [MaxLength(80)]
    [Display(Name = "Medical License / MMC")]
    public string? MedicalLicenseNo { get; set; }

    [Required(ErrorMessage = "Primary Speciality is required.")]
    [Display(Name = "Speciality (Primary)")]
    public int? PrimarySpecialityId { get; set; }

    [Display(Name = "Secondary Speciality")]
    public int? SecondarySpecialityId { get; set; }

    [DataType(DataType.Date)]
    [Display(Name = "Joining Date")]
    public DateTime? JoiningDate { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    [Display(Name = "Is Referral Doctor")]
    public bool IsReferralDoctor { get; set; }

    // ── Login Account Section ─────────────────────────────────────────────────
    /// <summary>Flag: if true, create/update a linked User login account for this doctor.</summary>
    [Display(Name = "Is Login Required")]
    public bool IsLoginRequired { get; set; }

    /// <summary>FK to Users.Id — populated when editing a doctor that already has a login.</summary>
    public int? LinkedUserId { get; set; }

    /// <summary>
    /// The doctor's own login (Users.User_Type = 'D', ReferenceUserID = DoctorId), whether switched on or not.
    /// Set by the server only; a switched-off login is re-activated, never duplicated.
    /// </summary>
    public int? LoginAccountId { get; set; }

    /// <summary>Login username for the doctor's system account.</summary>
    [MaxLength(100)]
    [Display(Name = "Username")]
    public string? LoginUsername { get; set; }

    /// <summary>Plain-text password — hashed before persisting. Optional on edit.</summary>
    [DataType(DataType.Password)]
    [Display(Name = "Password")]
    public string? LoginPassword { get; set; }

    /// <summary>Confirmation of the password — validated client & server side.</summary>
    [DataType(DataType.Password)]
    [Display(Name = "Confirm Password")]
    public string? LoginConfirmPassword { get; set; }

    public List<int> SelectedBranchIds { get; set; } = [];
    public List<int> SelectedDepartmentIds { get; set; } = [];

    public bool CanAssignMultipleBranches { get; set; }
    public int CurrentBranchId { get; set; }
    public string CurrentBranchName { get; set; } = string.Empty;

    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
}

/// <summary>Master > Doctor Master list, one page of doctors from the server (SQLScripts/2315).</summary>
public class DoctorListPageViewModel
{
    public List<DoctorListItemViewModel> Items { get; set; } = new();
    public int TotalDoctors { get; set; }
    public int ActiveDoctors { get; set; }
    public int InactiveDoctors { get; set; }
    public int OpdDoctors { get; set; }
    public int WithFees { get; set; }
    public int FilteredCount { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
    public string? Search { get; set; }
    public string? Status { get; set; }
    public string? Referral { get; set; }
    public string? Speciality { get; set; }
    public string? Department { get; set; }
    public int? DoctorId { get; set; }
    public List<string> Specialities { get; set; } = new();
    /// <summary>Department name and its type (OPD / IPD / LAB) for the filter labels.</summary>
    public List<(string Name, string Type)> Departments { get; set; } = new();
    public int TotalPages => PageSize > 0 ? Math.Max(1, (int)Math.Ceiling(FilteredCount / (double)PageSize)) : 1;
    public bool HasFilter => !string.IsNullOrWhiteSpace(Search) || !string.IsNullOrWhiteSpace(Status) || !string.IsNullOrWhiteSpace(Referral)
                             || !string.IsNullOrWhiteSpace(Speciality) || !string.IsNullOrWhiteSpace(Department) || DoctorId is > 0;
}

public class DoctorListItemViewModel
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string PrimarySpecialityName { get; set; } = string.Empty;
    public string DepartmentNames { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string EmailId { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    /// <summary>Comma-separated "ItemName (₹Charges)" for all mapped consulting fees.</summary>
    public string ConsultingFeeNames { get; set; } = string.Empty;
    /// <summary>True when doctor has at least one OPD-type department mapped.</summary>
    public bool HasOPDDept { get; set; }
    public bool IsReferralDoctor { get; set; }
}

public class ConsultingFeeItemDto
{
    public int MappingId   { get; set; }
    public int ServiceId   { get; set; }
    public string ItemCode  { get; set; } = string.Empty;
    public string ItemName  { get; set; } = string.Empty;
    public decimal ItemCharges { get; set; }
    public string? ConsultingType { get; set; }
    public int? GraceTime { get; set; }
}

public class ConsultingServiceOptionDto
{
    public int ServiceId    { get; set; }
    public string ItemCode   { get; set; } = string.Empty;
    public string ItemName   { get; set; } = string.Empty;
    public decimal ItemCharges { get; set; }
    public string? ConsultingType { get; set; }
    public string Label => $"{ItemCode} — {ItemName} (₹{ItemCharges:N2})";
}

public class DoctorDetailsViewModel
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public DateTime? DateOfBirth { get; set; }
    public string EmailId { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string? MedicalLicenseNo { get; set; }

    public int PrimarySpecialityId { get; set; }
    public string PrimarySpecialityName { get; set; } = string.Empty;

    public int? SecondarySpecialityId { get; set; }
    public string? SecondarySpecialityName { get; set; }

    public DateTime? JoiningDate { get; set; }
    public bool IsActive { get; set; }
    public bool IsReferralDoctor { get; set; }

    public List<string> BranchNames { get; set; } = [];
    public List<string> DepartmentNames { get; set; } = [];
    public List<ConsultingFeeItemDto> ConsultingFees { get; set; } = [];

    public int? LinkedUserId { get; set; }
    public string? LoginUsername { get; set; }
    public bool IsLoginActive { get; set; }

    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
