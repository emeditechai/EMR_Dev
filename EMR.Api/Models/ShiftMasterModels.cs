namespace EMR.Api.Models;

public class ShiftMasterListItemDto
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
}

public class ShiftMasterDetailDto : ShiftMasterListItemDto
{
}

public class ShiftMasterSaveRequest
{
    public int? ShiftMaster_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string ShiftCode { get; set; } = string.Empty;
    public string ShiftName { get; set; } = string.Empty;
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public int GraceTimeMinutes { get; set; } = 15;
    public int BreakDurationMinutes { get; set; } = 30;
    public bool IsNightShift { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}
