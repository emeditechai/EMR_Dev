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
    public DateTime? DateOfBirth { get; set; }
    /// <summary>Computed from DateOfBirth; not stored in DB.</summary>
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
    public DateTime CreatedDate { get; set; }
    public bool IsActive { get; set; }
    public string? ConsultingDoctorName { get; set; }
    /// <summary>Populated by usp_GetPatientListPaged via COUNT(*) OVER().</summary>
    public int TotalCount { get; set; }
}

// ─── Paged wrapper for OPD Index ──────────────────────────────────────────────
public class PatientPagedListViewModel
{
    public List<PatientListItemViewModel> Items { get; set; } = [];
    public int TotalCount { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 10;
    public string? Search { get; set; }
    public int TotalPages => PageSize > 0 ? (int)Math.Ceiling((double)TotalCount / PageSize) : 1;
    public bool HasPrev => Page > 1;
    public bool HasNext => Page < TotalPages;
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

    [Required(ErrorMessage = "Relation is required.")]
    [Display(Name = "Relation")]
    public int? RelationId { get; set; }

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

    [Display(Name = "Date of Birth")]
    public DateTime? DateOfBirth { get; set; }

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

    [MaxLength(500)]
    [Display(Name = "Address")]
    public string? Address { get; set; }

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

    /// <summary>ID of the PatientOPDService (bill header) row; 0 = new visit.</summary>
    public int OPDServiceId { get; set; }

    [Display(Name = "Consulting Doctor")]
    public int? ConsultingDoctorId { get; set; }

    /// <summary>Line items — serialised to JSON and sent as a single hidden field.</summary>
    public string LineItemsJson { get; set; } = "[]";

    // ── Select Lists (populated from server) ─────────────────────────────────

    public List<SelectListItem> ReligionOptions { get; set; } = [];
    public List<SelectListItem> RelationOptions { get; set; } = [];
    public List<SelectListItem> IdentificationTypeOptions { get; set; } = [];
    public List<SelectListItem> OccupationOptions { get; set; } = [];
    public List<SelectListItem> MaritalStatusOptions { get; set; } = [];
    public List<SelectListItem> CountryOptions { get; set; } = [];
    public List<SelectListItem> StateOptions { get; set; } = [];
    public List<SelectListItem> DistrictOptions { get; set; } = [];
    public List<SelectListItem> CityOptions { get; set; } = [];
    public List<SelectListItem> AreaOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];

    // ── After-save info (used by success modal) ───────────────────────────────
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    /// <summary>ID of the newly created OPDService row — used to build Print Bill URL.</summary>
    public int? NewOPDServiceId { get; set; }

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
    public string? SecondaryPhoneNumber { get; set; }
    public string? Gender { get; set; }
    public string? BloodGroup { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string? Address { get; set; }
    public string? RelationName { get; set; }
    public string? LastOpdBillNo { get; set; }
    /// <summary>Computed from DateOfBirth.</summary>
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
}

// ─── OPD Service Line Item DTO (used for JSON serialization) ─────────────────
public class OPDServiceLineItem
{
    public string? ServiceType { get; set; }
    public int? ServiceId { get; set; }
    public string? ItemName { get; set; }
    public decimal ServiceCharges { get; set; }
}

// ─── Service Booking List Item (for ServiceBooking grid) ─────────────────────
public class ServiceBookingListItem
{
    public int OPDServiceId { get; set; }
    public DateTime VisitDate { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public int PatientId { get; set; }
    public string PatientName { get; set; } = string.Empty;
    public string? Gender { get; set; }
    public int? Age { get; set; }
    public string? ConsultingDoctorName { get; set; }
    public decimal TotalAmount { get; set; }
    public string Status { get; set; } = string.Empty;
    // Line items (comma-joined for display)
    public string ServiceTypesSummary { get; set; } = string.Empty;    // Window-function aggregates from usp_GetServiceBookingsPaged
    public int TotalCount { get; set; }
    public decimal TotalFeesAll { get; set; }
    public int RegisteredCount { get; set; }
    public int CompletedCount { get; set; }
}

// ─── Paged wrapper for ServiceBooking list ───────────────────────────────────────
public class ServiceBookingPagedListViewModel
{
    public List<ServiceBookingListItem> Items { get; set; } = [];
    public int TotalCount { get; set; }
    public decimal TotalFeesAll { get; set; }
    public int RegisteredCount { get; set; }
    public int CompletedCount { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 10;
    public string? Search { get; set; }
    public string? FromDate { get; set; }
    public string? ToDate { get; set; }
    public int TotalPages => PageSize > 0 ? (int)Math.Ceiling((double)TotalCount / PageSize) : 1;
    public bool HasPrev => Page > 1;
    public bool HasNext => Page < TotalPages;}

// ─── Detail popup DTO ─────────────────────────────────────────────────────────
public class ServiceBookingDetailItem
{
    public string? ServiceType { get; set; }
    public string? ItemName { get; set; }
    public decimal ServiceCharges { get; set; }
}

public class ServiceBookingDetailViewModel
{
    public int OPDServiceId { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
    public string? ConsultingDoctorName { get; set; }
    public DateTime VisitDate { get; set; }
    public decimal TotalAmount { get; set; }
    public string Status { get; set; } = string.Empty;
    public List<ServiceBookingDetailItem> Items { get; set; } = [];
}
