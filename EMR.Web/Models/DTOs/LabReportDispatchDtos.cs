namespace EMR.Web.Models.DTOs;

/// <summary>Summary cards of the Lab Report Dispatch dashboard.</summary>
public class LabReportDispatchStatsDto
{
    public int TotalBills { get; set; }
    public int ReadyBills { get; set; }
    public int PartialBills { get; set; }
    public int AwaitingBills { get; set; }
    public int InProgressBills { get; set; }
    public int PrintedBills { get; set; }
    public int NotPrintedBills { get; set; }
    public int ReadyPaymentDueBills { get; set; }
    public int UrgentPendingBills { get; set; }
    public int CriticalBills { get; set; }
    public int B2BBills { get; set; }
    public int B2CBills { get; set; }
    public int TotalTests { get; set; }
    public int ApprovedTests { get; set; }
    public int ValidatedTests { get; set; }
    public decimal? AvgTatMinutes { get; set; }
}

/// <summary>One bill (Lab Order) row of the dispatch list.</summary>
public class LabReportDispatchRowDto
{
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public bool IsUrgent { get; set; }
    public DateTime BillingDate { get; set; }
    public DateTime BookingDateTime { get; set; }
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string PatientName { get; set; } = string.Empty;
    public int? Age { get; set; }
    public string? Gender { get; set; }
    public string? PhoneNumber { get; set; }
    public string BillingType { get; set; } = "B2C";
    public string? ClientType { get; set; }
    public string? ClientCode { get; set; }
    public string? ClientName { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public decimal BalanceDue { get; set; }
    public decimal TotalAmount { get; set; }
    public int TotalTests { get; set; }
    public int CollectedTests { get; set; }
    public int RecollectTests { get; set; }
    public int EnteredTests { get; set; }
    public int ValidatedTests { get; set; }
    public int ApprovedTests { get; set; }
    public int CriticalTests { get; set; }
    public DateTime? ApprovedDate { get; set; }
    /// <summary>READY | PARTIAL | AWAITING | INPROGRESS | NOTSTARTED</summary>
    public string DispatchStatus { get; set; } = "NOTSTARTED";
    public bool CanPrint { get; set; }
    public int PrintCount { get; set; }
    public DateTime? LastPrintedDate { get; set; }
    public bool PrintedAfterApproval { get; set; }
    public int? TatMinutes { get; set; }
}

public class LabReportDispatchResult
{
    public LabReportDispatchStatsDto Stats { get; set; } = new();
    public List<LabReportDispatchRowDto> Rows { get; set; } = new();
}

/// <summary>One test of a bill, as shown by the dispatch list's "view tests" modal.</summary>
public class LabReportDispatchTestDto
{
    public long SamplecollectionID { get; set; }
    public string? TestCode { get; set; }
    public string TestName { get; set; } = string.Empty;
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
    public string? GroupName { get; set; }
    public string? SampleTypeName { get; set; }
    public string? ContainerType { get; set; }
    public string? BarcodeNo { get; set; }
    public int CollectionstatusID { get; set; }
    public string? SampleStatusName { get; set; }
    public string? RejectionReason { get; set; }
    public DateTime? CollectedOn { get; set; }
    public DateTime? ReceivedDate { get; set; }
    public bool IsTransferred { get; set; }
    public string? TargetBranchName { get; set; }
    public int ReportStatusId { get; set; }
    public string? ReportStatusName { get; set; }
    public DateTime? DraftedDate { get; set; }
    public DateTime? SubmittedDate { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public int? TatMinutes { get; set; }
}
