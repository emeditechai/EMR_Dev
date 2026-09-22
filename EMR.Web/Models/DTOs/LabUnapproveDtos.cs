namespace EMR.Web.Models.DTOs;

public class LabUnapproveStatsDto
{
    public int TotalBills { get; set; }
    public int FullyApprovedBills { get; set; }
    public int PartiallyApprovedBills { get; set; }
    public int ApprovedTests { get; set; }
}

public class LabUnapproveHeaderDto
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
    public string BillingType { get; set; } = "B2C";
    public string? ClientName { get; set; }
    public int TotalTests { get; set; }
    public int ApprovedTests { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string ApprovalType { get; set; } = "PARTIAL";
    public string? PaymentStatus { get; set; }
    public int UnapprovalCount { get; set; }
}

public class LabUnapproveListResult
{
    public LabUnapproveStatsDto Stats { get; set; } = new();
    public List<LabUnapproveHeaderDto> Headers { get; set; } = [];
}

public class LabUnapproveBillDto
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
    public string BillingType { get; set; } = "B2C";
    public string? ClientName { get; set; }
}

public class LabUnapproveTestDto
{
    public long SamplecollectionID { get; set; }
    public int InvestigationID { get; set; }
    public string? TestCode { get; set; }
    public string TestName { get; set; } = string.Empty;
    public int? ProfileId { get; set; }
    public string? ProfileName { get; set; }
    public string? GroupName { get; set; }
    public string? DepartmentName { get; set; }
    public string? TestValue { get; set; }
    public string? AbnormalFlag { get; set; }
    public string? ReportingType { get; set; }
    public int ReportStatusId { get; set; }
    public string? ReportStatusName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public bool IsApproved { get; set; }
}

public class LabUnapproveDetailResult
{
    public LabUnapproveBillDto? Bill { get; set; }
    public List<LabUnapproveTestDto> Tests { get; set; } = [];
}

public class LabUnapproveRequest
{
    public int LabOrderId { get; set; }
    public List<long> SamplecollectionIds { get; set; } = [];
    public string? Reason { get; set; }
    /// <summary>RETEST (back to Submitted, value kept) or RECOLLECT (sample goes back to Sample Collection).</summary>
    public string? Action { get; set; }
    public int UserId { get; set; }
}
