using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels
{
    public class LabOrderBookingViewModel
    {
        public int PatientId { get; set; }
        public string? PatientCode { get; set; }

        // ── Section 1: Demography ──────────────────────────────────────────────────
        [MaxLength(10)]
        [Display(Name = "Blood Group")]
        public string? BloodGroup { get; set; }

        [Required(ErrorMessage = "Phone number is required.")]
        [MaxLength(15, ErrorMessage = "Phone number cannot exceed 15 characters.")]
        [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Enter a valid 10-digit mobile number.")]
        [Display(Name = "Phone Number")]
        public string PhoneNumber { get; set; } = string.Empty;

        [Required(ErrorMessage = "Relation is required.")]
        [Display(Name = "Relation")]
        public int? RelationId { get; set; }

        [MaxLength(10)]
        [Display(Name = "Salutation")]
        public string? Salutation { get; set; }

        [Required(ErrorMessage = "First name is required.")]
        [MaxLength(100)]
        [Display(Name = "First Name")]
        public string FirstName { get; set; } = string.Empty;

        [MaxLength(100)]
        [Display(Name = "Last Name")]
        public string LastName { get; set; } = string.Empty;

        [Required(ErrorMessage = "Gender is required.")]
        [Display(Name = "Gender")]
        public string Gender { get; set; } = string.Empty;

        [Display(Name = "Date of Birth")]
        public DateTime? DateOfBirth { get; set; }

        [Display(Name = "Age (Years)")]
        [Range(0, 150, ErrorMessage = "Years must be between 0 and 150.")]
        public int? AgeYears { get; set; }

        [Display(Name = "Age (Months)")]
        [Range(0, 12, ErrorMessage = "Months cannot exceed 12.")]
        public int? AgeMonths { get; set; }

        [Display(Name = "Age (Days)")]
        [Range(0, 30, ErrorMessage = "Days cannot exceed 30.")]
        public int? AgeDays { get; set; }

        [EmailAddress(ErrorMessage = "Enter a valid email address.")]
        [MaxLength(150)]
        [Display(Name = "Email ID")]
        public string? EmailId { get; set; }

        [MaxLength(15, ErrorMessage = "Secondary number cannot exceed 15 characters.")]
        [RegularExpression(@"^[6-9]\d{9}$", ErrorMessage = "Enter a valid 10-digit mobile number.")]
        [Display(Name = "Secondary Phone Number")]
        public string? SecondaryPhoneNumber { get; set; }

        [MaxLength(100)]
        [Display(Name = "Middle Name")]
        public string? MiddleName { get; set; }

        [Display(Name = "Religion")]
        public int? ReligionId { get; set; }

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

        [MaxLength(500)]
        [Display(Name = "Home Collection Address")]
        public string? HomeCollectionAddress { get; set; }

        [Display(Name = "Latitude")]
        public decimal? Latitude { get; set; }

        [Display(Name = "Longitude")]
        public decimal? Longitude { get; set; }

        [Display(Name = "Identification Type")]
        public int? IdentificationTypeId { get; set; }

        [MaxLength(100)]
        [Display(Name = "Identification Number")]
        public string? IdentificationNumber { get; set; }

        // ── Section 2: Other Info ─────────────────────────────────────────────────

        [Display(Name = "Occupation")]
        public int? OccupationId { get; set; }

        [Display(Name = "Marital Status")]
        public int? MaritalStatusId { get; set; }

        [Display(Name = "Language")]
        public int? LanguageId { get; set; } = 1;

        [Display(Name = "Referral Doctor")]
        public int? ReferralDoctorId { get; set; }

        [MaxLength(500)]
        [Display(Name = "Known Allergies")]
        public string? KnownAllergies { get; set; }

        [MaxLength(1000)]
        [Display(Name = "Remarks")]
        public string? Remarks { get; set; }

        public string? IdentificationFilePath { get; set; }
        public string? PhotoPath { get; set; }

        // ── Section 2: LAB Order Booking Settings ──────────────────────────────
        [Display(Name = "Collection Type")]
        public string CollectionType { get; set; } = "Lab";

        [Display(Name = "Phlebotomist")]
        public int? PhlebotomistId { get; set; }

        [Display(Name = "Booking Date & Time")]
        public DateTime BookingDateTime { get; set; } = DateTime.Now;

        // ── Section 2: LAB Order Filters ─────────────────────────────────────────
        [Display(Name = "Department")]
        public int? DepartmentId { get; set; }
        [Display(Name = "Category")]
        public int? CategoryId { get; set; }
        [Display(Name = "Sub Category")]
        public int? SubCategoryId { get; set; }

        /// <summary>Line items — serialised to JSON and sent as a single hidden field.</summary>
        public string LineItemsJson { get; set; } = "[]";
        
        public bool DemographicsOnly { get; set; }

        // ── Select Lists (populated from server) ─────────────────────────────────
        public List<SelectListItem> RelationOptions { get; set; } = new();
        public List<SelectListItem> ReligionOptions { get; set; } = new();
        public List<SelectListItem> MaritalStatusOptions { get; set; } = new();
        public List<SelectListItem> LanguageOptions { get; set; } = new();
        public List<SelectListItem> OccupationOptions { get; set; } = new();
        public List<SelectListItem> IdentificationTypeOptions { get; set; } = new();
        public List<SelectListItem> CountryOptions { get; set; } = new();
        public List<SelectListItem> BloodGroupOptions { get; set; } = new();
        public List<SelectListItem> ReferralDoctorOptions { get; set; } = new();
        public List<SelectListItem> StateOptions { get; set; } = new();
        public List<SelectListItem> DistrictOptions { get; set; } = new();
        public List<SelectListItem> CityOptions { get; set; } = new();
        public List<SelectListItem> AreaOptions { get; set; } = new();
        public List<SelectListItem> PhlebotomistOptions { get; set; } = new();
        
        public List<SelectListItem> DepartmentOptions { get; set; } = new();
        public List<SelectListItem> CategoryOptions { get; set; } = new();
        public List<SelectListItem> SubCategoryOptions { get; set; } = new();
    }

    public class LabOrderPagedListViewModel
    {
        public List<DTOs.LabOrderListItemDto> Items { get; set; } = new();
        public DTOs.LabOrderStatsDto Stats { get; set; } = new();
        public int TotalCount { get; set; }
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 10;
        public string? FromDate { get; set; }
        public string? ToDate { get; set; }
        public string? Search { get; set; }

        public int TotalPages => PageSize > 0 ? (int)Math.Ceiling((double)TotalCount / PageSize) : 0;
        public bool HasPrevious => Page > 1;
        public bool HasNext => Page < TotalPages;
    }
}
