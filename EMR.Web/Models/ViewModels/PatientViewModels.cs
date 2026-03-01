using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

// ─── List Item (for Patient Master grid) ──────────────────────────────────────
public class PatientListItemViewModel
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string? Gender { get; set; }
    public string? BloodGroup { get; set; }
    public DateTime CreatedDate { get; set; }
    public bool IsActive { get; set; }
    public string? ConsultingDoctorName { get; set; }
}

// ─── Full Form ViewModel ───────────────────────────────────────────────────────
public class PatientRegistrationViewModel
{
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }

    // ── Section 1: Demography ──────────────────────────────────────────────────

    [Required(ErrorMessage = "Phone number is required.")]
    [MaxLength(15, ErrorMessage = "Phone number cannot exceed 15 characters.")]
    [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Enter a valid 10-digit mobile number.")]
    [Display(Name = "Phone Number")]
    public string PhoneNumber { get; set; } = string.Empty;

    [MaxLength(15, ErrorMessage = "Secondary number cannot exceed 15 characters.")]
    [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Enter a valid 10-digit mobile number.")]
    [Display(Name = "Secondary Phone Number")]
    public string? SecondaryPhoneNumber { get; set; }

    [MaxLength(10)]
    [Display(Name = "Salutation")]
    public string? Salutation { get; set; }

    [Required(ErrorMessage = "First name is required.")]
    [MaxLength(100)]
    [Display(Name = "First Name")]
    public string FirstName { get; set; } = string.Empty;

    [MaxLength(100)]
    [Display(Name = "Middle Name")]
    public string? MiddleName { get; set; }

    [Required(ErrorMessage = "Last name is required.")]
    [MaxLength(100)]
    [Display(Name = "Last Name")]
    public string LastName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Gender is required.")]
    [Display(Name = "Gender")]
    public string Gender { get; set; } = string.Empty;

    [Display(Name = "Religion")]
    public int? ReligionId { get; set; }

    [EmailAddress(ErrorMessage = "Enter a valid email address.")]
    [MaxLength(150)]
    [Display(Name = "Email ID")]
    public string? EmailId { get; set; }

    [MaxLength(200)]
    [Display(Name = "Guardian Name")]
    public string? GuardianName { get; set; }

    [Display(Name = "Country")]
    public int? CountryId { get; set; }

    [Display(Name = "State")]
    public int? StateId { get; set; }

    [Display(Name = "District")]
    public int? DistrictId { get; set; }

    [Display(Name = "City")]
    public int? CityId { get; set; }

    [Display(Name = "Area")]
    public int? AreaId { get; set; }

    [Display(Name = "Identification Type")]
    public int? IdentificationTypeId { get; set; }

    [MaxLength(100)]
    [Display(Name = "Identification Number")]
    public string? IdentificationNumber { get; set; }

    // Holds the stored file path (on server); uploaded via IFormFile
    public string? IdentificationFilePath { get; set; }

    // ── Section 2: Other Info ─────────────────────────────────────────────────

    [Display(Name = "Occupation")]
    public int? OccupationId { get; set; }

    [Display(Name = "Marital Status")]
    public int? MaritalStatusId { get; set; }

    [MaxLength(10)]
    [Display(Name = "Blood Group")]
    public string? BloodGroup { get; set; }

    [MaxLength(500)]
    [Display(Name = "Known Allergies")]
    public string? KnownAllergies { get; set; }

    [MaxLength(1000)]
    [Display(Name = "Remarks")]
    public string? Remarks { get; set; }

    // ── Section 3: Doctor & Services ─────────────────────────────────────────

    /// <summary>ID of the PatientOPDService row being edited; 0 = new visit.</summary>
    public int OPDServiceId { get; set; }

    [Display(Name = "Consulting Doctor")]
    public int? ConsultingDoctorId { get; set; }

    [MaxLength(20)]
    [Display(Name = "Service Type")]
    public string? ServiceType { get; set; }   // "Consulting" or "Services"

    [Display(Name = "Service / Item")]
    public int? ServiceId { get; set; }

    public decimal? ServiceCharges { get; set; }

    // ── Select Lists (populated from server) ─────────────────────────────────

    public List<SelectListItem> ReligionOptions { get; set; } = [];
    public List<SelectListItem> IdentificationTypeOptions { get; set; } = [];
    public List<SelectListItem> OccupationOptions { get; set; } = [];
    public List<SelectListItem> MaritalStatusOptions { get; set; } = [];
    public List<SelectListItem> CountryOptions { get; set; } = [];
    public List<SelectListItem> StateOptions { get; set; } = [];
    public List<SelectListItem> DistrictOptions { get; set; } = [];
    public List<SelectListItem> CityOptions { get; set; } = [];
    public List<SelectListItem> AreaOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> ServiceOptions { get; set; } = [];

    /// <summary>
    /// True when opened via direct edit (edit button on list) — only demographics
    /// are saved; Doctor &amp; Services section is hidden and no OPD row is created.
    /// </summary>
    public bool DemographicsOnly { get; set; }
}

// ─── Quick-search result (by phone / patient code) ────────────────────────────
public class PatientQuickSearchResult
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string PhoneNumber { get; set; } = string.Empty;
    public string? Gender { get; set; }
    public string? BloodGroup { get; set; }
}
