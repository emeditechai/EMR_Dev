namespace EMR.Web.Models.DTOs;

/// <summary>Who the pathologist is and what they are allowed to filter by.</summary>
public class PathologistProfileDto
{
    public int UserId { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    public string? SignaturePath { get; set; }
    public bool IsPathologist { get; set; }
    public bool HasBranchAccess { get; set; }
    public string? DepartmentIds { get; set; }
    public string? CategoryIds { get; set; }
    public string? BranchName { get; set; }
}

public class PathologistDepartmentDto
{
    public int DepartmentId { get; set; }
    public string? DepartmentName { get; set; }
}

public class PathologistCategoryDto
{
    public int CategoryId { get; set; }
    public string? CategoryName { get; set; }
    public int? DepartmentId { get; set; }
}

public class PathologistAccessResult
{
    public PathologistProfileDto? Profile { get; set; }
    public List<PathologistDepartmentDto> Departments { get; set; } = [];
    public List<PathologistCategoryDto> Categories { get; set; } = [];
}

public class PathologistDashboardStatsDto
{
    public int TotalBills { get; set; }
    public int AwaitingMeBills { get; set; }
    public int AwaitingOtherBills { get; set; }
    public int ApprovedBills { get; set; }
    public int AwaitingMeTests { get; set; }
    public int ApprovedTests { get; set; }
    public int TotalTests { get; set; }
    public int UrgentAwaitingBills { get; set; }
}

public class PathologistBillDto
{
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public bool IsUrgent { get; set; }
    public DateTime BillingDate { get; set; }
    public DateTime BookingDateTime { get; set; }
    public string? PatientCode { get; set; }
    public string PatientName { get; set; } = string.Empty;
    public int? Age { get; set; }
    public string? Gender { get; set; }
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string BillingType { get; set; } = "B2C";
    public string? ClientName { get; set; }
    public int ScopeTests { get; set; }
    public int AwaitingMeTests { get; set; }
    public int ApprovedTests { get; set; }
    public int AwaitingOthersTests { get; set; }
    public int TotalLevels { get; set; }
    public int LevelsDone { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public string? FlowName { get; set; }
    public string? DashboardStatus { get; set; }
    public string? Departments { get; set; }
    public string? Categories { get; set; }
}

public class PathologistDashboardListResult
{
    public PathologistDashboardStatsDto Stats { get; set; } = new();
    public List<PathologistBillDto> Bills { get; set; } = [];
}

public class PathologistTestDto
{
    public long SamplecollectionID { get; set; }
    public int InvestigationID { get; set; }
    public string? TestCode { get; set; }
    public string TestName { get; set; } = string.Empty;
    public string? GroupName { get; set; }
    public int? ProfileId { get; set; }
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
    public string? BarcodeNo { get; set; }
    public string? TestValue { get; set; }
    public string? AbnormalFlag { get; set; }
    public string? Remarks { get; set; }
    public string? ReportingType { get; set; }
    public string? UnitName { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? ValidatedByName { get; set; }
    public int ReportStatusId { get; set; }
    public int? Flow_ID { get; set; }
    public string? Flow_Name { get; set; }
    public int TotalLevels { get; set; }
    public int LevelsDone { get; set; }
    public int? NextLevelNo { get; set; }
    public bool CanApproveNow { get; set; }
    public bool IsApproved { get; set; }
    public string? NextLevelApprovers { get; set; }
    public string? NextLevelTitle { get; set; }
    // Prior result for delta check (same patient + investigation, most recent earlier order)
    public string? PreviousTestValue { get; set; }
    public DateTime? PreviousOrderDate { get; set; }
    public string? PreviousUnitSymbol { get; set; }
}

public class PathologistApprovalHistoryDto
{
    public long SamplecollectionID { get; set; }
    public int Level_No { get; set; }
    public int TotalLevels { get; set; }
    public bool IsFinalLevel { get; set; }
    public DateTime ApprovedDate { get; set; }
    public string? Remarks { get; set; }
    public string? ApprovedByName { get; set; }
    public string? TestName { get; set; }
    public string? LevelTitle { get; set; }
}

public class PathologistDetailResult
{
    public PathologistBillDto? Bill { get; set; }
    public List<PathologistTestDto> Tests { get; set; } = [];
    public List<PathologistApprovalHistoryDto> History { get; set; } = [];
}

public class PathologistApproveRequest
{
    public int LabOrderId { get; set; }
    public List<long> SamplecollectionIds { get; set; } = [];
    public int UserId { get; set; }
    public int BranchId { get; set; }
    public string? Remarks { get; set; }
}

public class PathologistApproveResult
{
    public int SignedCount { get; set; }
    public int FinalApprovedCount { get; set; }
}
