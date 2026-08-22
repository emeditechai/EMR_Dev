using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

// ── HK Location ViewModels ───────────────────────────────────────────────────
public class HKLocationItemViewModel
{
    public int Location_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string LocationType { get; set; } = string.Empty; // Ward, Room, Toilet, ICU, OT, OPD, Public Area
    public int Reference_ID { get; set; }
    public string? ReferenceEntityName { get; set; }
    public string LocationCode { get; set; } = string.Empty;
    public string LocationName { get; set; } = string.Empty;
    public int? Floor_ID { get; set; }
    public string? FloorName { get; set; }
    public int? Building_ID { get; set; }
    public string? BuildingName { get; set; }
    public string RiskLevel { get; set; } = "Moderate Risk";
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int AssignedStaffCount { get; set; }
}

public class HKLocationFormModel
{
    public int Location_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Location Type is mandatory.")]
    [Display(Name = "Location Type")]
    public string LocationType { get; set; } = "Ward"; // Ward, Room, Toilet, ICU, OT, OPD, Public Area

    [Display(Name = "Physical Master Reference")]
    public int Reference_ID { get; set; } = 0;

    [Required(ErrorMessage = "Location Code is mandatory.")]
    [StringLength(50)]
    [Display(Name = "Location Code")]
    public string LocationCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Location Name is mandatory.")]
    [StringLength(200)]
    [Display(Name = "Location Name / Zone Title")]
    public string LocationName { get; set; } = string.Empty;

    [Display(Name = "Floor")]
    public int? Floor_ID { get; set; }

    [Display(Name = "Building Complex")]
    public int? Building_ID { get; set; }

    [Required(ErrorMessage = "Risk Level is mandatory.")]
    [Display(Name = "Infection Control Risk Level")]
    public string RiskLevel { get; set; } = "Moderate Risk"; // High Risk, Moderate Risk, Low Risk

    [Display(Name = "Active Status")]
    public bool Status { get; set; } = true;
}

public class HKPhysicalMasterItemViewModel
{
    public int Reference_ID { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public int? Floor_ID { get; set; }
    public int? Building_ID { get; set; }
}

// ── HK Cleaning ViewModels ───────────────────────────────────────────────────
public class HKCleaningItemViewModel
{
    public int Cleaning_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string CleaningType { get; set; } = string.Empty;
    public string Frequency { get; set; } = string.Empty;
    public int? ChecklistTemplate_ID { get; set; }
    public string? ChecklistTemplateName { get; set; }
    public string? ChecklistTemplateCode { get; set; }
    public string ChemicalUsed { get; set; } = string.Empty;
    public string EquipmentUsed { get; set; } = string.Empty;
    public int SLA_Minutes { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class HKCleaningFormModel
{
    public int Cleaning_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Cleaning Type is mandatory.")]
    [StringLength(100)]
    [Display(Name = "Cleaning Protocol / Type")]
    public string CleaningType { get; set; } = string.Empty;

    [Required(ErrorMessage = "Frequency is mandatory.")]
    [StringLength(100)]
    [Display(Name = "Sanitation Frequency")]
    public string Frequency { get; set; } = "Every 4 Hours";

    [Display(Name = "Standard Checklist Template")]
    public int? ChecklistTemplate_ID { get; set; }

    [Required(ErrorMessage = "Chemical Used is mandatory.")]
    [StringLength(200)]
    [Display(Name = "Chemical / Disinfectant Used")]
    public string ChemicalUsed { get; set; } = string.Empty;

    [Required(ErrorMessage = "Equipment Used is mandatory.")]
    [StringLength(200)]
    [Display(Name = "Equipment / Tools Used")]
    public string EquipmentUsed { get; set; } = string.Empty;

    [Range(5, 300, ErrorMessage = "SLA Minutes must be between 5 and 300 minutes.")]
    [Display(Name = "SLA Target Turnaround (Minutes)")]
    public int SLA_Minutes { get; set; } = 30;

    [Display(Name = "Active Status")]
    public bool Status { get; set; } = true;
}

// ── HK Staff ViewModels ─────────────────────────────────────────────────────
public class HKStaffItemViewModel
{
    public int HKStaff_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int Staff_ID { get; set; }
    public string? StaffUsername { get; set; }
    public string? StaffName { get; set; }
    public string? StaffPhone { get; set; }
    public int ShiftMaster_ID { get; set; }
    public string? ShiftCode { get; set; }
    public string? ShiftName { get; set; }
    public TimeSpan ShiftStartTime { get; set; }
    public TimeSpan ShiftEndTime { get; set; }
    public int? Supervisor_ID { get; set; }
    public string? SupervisorUsername { get; set; }
    public string? SupervisorName { get; set; }
    public int AreaAllocation_ID { get; set; }
    public string? LocationCode { get; set; }
    public string? LocationName { get; set; }
    public string? LocationType { get; set; }
    public string? RiskLevel { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public string ShiftFormattedTime =>
        $"{DateTime.Today.Add(ShiftStartTime):hh:mm tt} - {DateTime.Today.Add(ShiftEndTime):hh:mm tt}";
}

public class HKStaffFormModel
{
    public int HKStaff_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Housekeeping Staff Member is mandatory.")]
    [Display(Name = "Staff Member (User Master)")]
    public int Staff_ID { get; set; }

    [Required(ErrorMessage = "Operational Shift is mandatory.")]
    [Display(Name = "Assigned Shift")]
    public int ShiftMaster_ID { get; set; }

    [Display(Name = "Shift Supervisor / In-Charge")]
    public int? Supervisor_ID { get; set; }

    [Required(ErrorMessage = "Area Allocation is mandatory.")]
    [Display(Name = "Allocated Location / Zone")]
    public int AreaAllocation_ID { get; set; }

    [Display(Name = "Active Status")]
    public bool Status { get; set; } = true;
}

// ── HK Checklist Template ViewModels ────────────────────────────────────────
public class HKChecklistTemplateViewModel
{
    public int Template_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string TemplateCode { get; set; } = string.Empty;
    public string TemplateName { get; set; } = string.Empty;
    public string? ChecklistItemsJSON { get; set; }
    public bool IsActive { get; set; }
}

// ── Integrated Housekeeping Workspace Master ViewModel ─────────────────────
public class HKIntegratedWorkspaceViewModel
{
    public string ActiveTab { get; set; } = "locations"; // "locations", "cleanings", "staff"
    public int SelectedBranchId { get; set; }

    // Lists for the 3 integrated modules
    public List<HKLocationItemViewModel> Locations { get; set; } = [];
    public List<HKCleaningItemViewModel> Cleanings { get; set; } = [];
    public List<HKStaffItemViewModel> StaffList { get; set; } = [];
    public List<HKChecklistTemplateViewModel> ChecklistTemplates { get; set; } = [];

    // Dropdown SelectLists
    public List<SelectListItem> LocationTypeOptions { get; set; } = [];
    public List<SelectListItem> RiskLevelOptions { get; set; } = [];
    public List<SelectListItem> FrequencyOptions { get; set; } = [];
    public List<SelectListItem> ShiftOptions { get; set; } = [];
    public List<SelectListItem> UserOptions { get; set; } = [];
    public List<SelectListItem> SupervisorOptions { get; set; } = [];
    public List<SelectListItem> LocationOptions { get; set; } = [];
    public List<SelectListItem> ChecklistTemplateOptions { get; set; } = [];
    public List<SelectListItem> BuildingOptions { get; set; } = [];
    public List<SelectListItem> FloorOptions { get; set; } = [];

    // Filter properties
    public string? LocationTypeFilter { get; set; }
    public string? CleaningTypeFilter { get; set; }
    public int? ShiftFilter { get; set; }
    public int? LocationFilter { get; set; }
    public bool? StatusFilter { get; set; }
    public string? SearchTerm { get; set; }

    // Summary Statistics
    public int TotalLocations => Locations.Count;
    public int ActiveLocations => Locations.Count(x => x.Status);
    public int TotalCleanings => Cleanings.Count;
    public int ActiveCleanings => Cleanings.Count(x => x.Status);
    public int TotalStaffAllocations => StaffList.Count;
    public int ActiveStaffAllocations => StaffList.Count(x => x.Status);
    public int HighRiskZonesCount => Locations.Count(x => x.RiskLevel == "High Risk");
}
