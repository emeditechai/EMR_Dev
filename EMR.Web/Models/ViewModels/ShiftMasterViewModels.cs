using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class ShiftMasterListItemViewModel
{
    public int ShiftMaster_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string ShiftCode { get; set; } = string.Empty;
    public string ShiftName { get; set; } = string.Empty;
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public int GraceTimeMinutes { get; set; }
    public int BreakDurationMinutes { get; set; }
    public bool IsNightShift { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int AssignedStaffCount { get; set; }

    public string FormattedTimeRange =>
        $"{DateTime.Today.Add(StartTime):hh:mm tt} - {DateTime.Today.Add(EndTime):hh:mm tt}";
}

public class ShiftMasterIndexViewModel
{
    public List<ShiftMasterListItemViewModel> ShiftList { get; set; } = [];
    public int SelectedBranchId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
    public List<SelectListItem> StatusOptions { get; set; } = [];
}

public class ShiftMasterFormViewModel
{
    public int ShiftMaster_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? Branch_ID { get; set; }

    [Required(ErrorMessage = "Shift Code is mandatory.")]
    [StringLength(50, ErrorMessage = "Shift Code cannot exceed 50 characters.")]
    [Display(Name = "Shift Code")]
    public string ShiftCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Shift Name is mandatory.")]
    [StringLength(100, ErrorMessage = "Shift Name cannot exceed 100 characters.")]
    [Display(Name = "Shift Name / Description")]
    public string ShiftName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Start Time is mandatory.")]
    [Display(Name = "Shift Start Time")]
    public TimeSpan StartTime { get; set; } = new TimeSpan(7, 0, 0);

    [Required(ErrorMessage = "End Time is mandatory.")]
    [Display(Name = "Shift End Time")]
    public TimeSpan EndTime { get; set; } = new TimeSpan(15, 0, 0);

    [Range(0, 120, ErrorMessage = "Grace time must be between 0 and 120 minutes.")]
    [Display(Name = "Grace Time (Minutes)")]
    public int GraceTimeMinutes { get; set; } = 15;

    [Range(0, 180, ErrorMessage = "Break duration must be between 0 and 180 minutes.")]
    [Display(Name = "Break Duration (Minutes)")]
    public int BreakDurationMinutes { get; set; } = 30;

    [Display(Name = "Is Night Shift (Crosses Midnight)")]
    public bool IsNightShift { get; set; } = false;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;
}
