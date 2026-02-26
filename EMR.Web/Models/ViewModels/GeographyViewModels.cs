using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

// ── Country ──────────────────────────────────────────
public class CountryFormViewModel
{
    public int CountryId { get; set; }

    [Required, MaxLength(20)]
    [Display(Name = "Country Code")]
    public string CountryCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    [Display(Name = "Country Name")]
    public string CountryName { get; set; } = string.Empty;

    [MaxLength(10)]
    [Display(Name = "Currency")]
    public string? Currency { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;
}

// ── State ─────────────────────────────────────────────
public class StateFormViewModel
{
    public int StateId { get; set; }

    [Required, MaxLength(20)]
    [Display(Name = "State Code")]
    public string StateCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    [Display(Name = "State Name")]
    public string StateName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Country")]
    public int CountryId { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public IEnumerable<SelectListItem> Countries { get; set; } = [];
}

// ── District ──────────────────────────────────────────
public class DistrictFormViewModel
{
    public int DistrictId { get; set; }

    [Required, MaxLength(20)]
    [Display(Name = "District Code")]
    public string DistrictCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    [Display(Name = "District Name")]
    public string DistrictName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Country")]
    public int CountryId { get; set; }

    [Required]
    [Display(Name = "State")]
    public int StateId { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public IEnumerable<SelectListItem> Countries { get; set; } = [];
    public IEnumerable<SelectListItem> States { get; set; } = [];
}

// ── City ──────────────────────────────────────────────
public class CityFormViewModel
{
    public int CityId { get; set; }

    [Required, MaxLength(20)]
    [Display(Name = "City Code")]
    public string CityCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    [Display(Name = "City Name")]
    public string CityName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Country")]
    public int CountryId { get; set; }

    [Required]
    [Display(Name = "State")]
    public int StateId { get; set; }

    [Required]
    [Display(Name = "District")]
    public int DistrictId { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public IEnumerable<SelectListItem> Countries { get; set; } = [];
    public IEnumerable<SelectListItem> States { get; set; } = [];
    public IEnumerable<SelectListItem> Districts { get; set; } = [];
}

// ── Area ──────────────────────────────────────────────
public class AreaFormViewModel
{
    public int AreaId { get; set; }

    [Required, MaxLength(20)]
    [Display(Name = "Area Code")]
    public string AreaCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    [Display(Name = "Area Name")]
    public string AreaName { get; set; } = string.Empty;

    [Required]
    [Display(Name = "Country")]
    public int CountryId { get; set; }

    [Required]
    [Display(Name = "State")]
    public int StateId { get; set; }

    [Required]
    [Display(Name = "District")]
    public int DistrictId { get; set; }

    [Required]
    [Display(Name = "City")]
    public int CityId { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public IEnumerable<SelectListItem> Countries { get; set; } = [];
    public IEnumerable<SelectListItem> States { get; set; } = [];
    public IEnumerable<SelectListItem> Districts { get; set; } = [];
    public IEnumerable<SelectListItem> Cities { get; set; } = [];
}
