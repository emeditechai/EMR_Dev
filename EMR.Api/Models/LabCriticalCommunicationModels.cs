namespace EMR.Api.Models;

/// <summary>A Critical / Panic result of a bill with its communication state (dbo.usp_LabCritical_GetPending RS1).</summary>
public class LabCriticalResultDto
{
    public long SampleId { get; set; }
    public int? LabEntryDetailId { get; set; }
    public int InvestigationID { get; set; }
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string? ProfileName { get; set; }
    public string? TestValue { get; set; }
    public string? Unit { get; set; }
    public string? Severity { get; set; }
    public string? ThresholdDir { get; set; }
    public string? Threshold { get; set; }
    public string? SavedFlag { get; set; }
    public int ReportStatusId { get; set; }
    public DateTime? EnteredOn { get; set; }
    public DateTime? ApprovedOn { get; set; }
    public bool IsFinal { get; set; }
    public int? NextLevelNo { get; set; }
    public int? TotalLevels { get; set; }
    public string CommunicationStatus { get; set; } = "NOTRECORDED";
    public long? InformedId { get; set; }
    public string? InformedName { get; set; }
    public string? InformedRole { get; set; }
    public string? InformedMode { get; set; }
    public DateTime? InformedOn { get; set; }
    public bool? ReadBack { get; set; }
    public bool ValueChangedSinceInformed { get; set; }
    public string? LastOutcome { get; set; }
    public string? LastName { get; set; }
    public string? LastMode { get; set; }
    public DateTime? LastOn { get; set; }
    public string? LastRemarks { get; set; }
    public string? LastMessageStatus { get; set; }
    public int Attempts { get; set; }
    public bool BlocksSignoff { get; set; }
}

/// <summary>Who can be informed about the bill (RS2), to prefill the form.</summary>
public class LabCriticalContactsDto
{
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public bool IsB2B { get; set; }
    public string? PatientName { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientPhone { get; set; }
    public string? PatientEmail { get; set; }
    public string? RefDoctorName { get; set; }
    public string? RefDoctorPhone { get; set; }
    public string? RefDoctorEmail { get; set; }
    public string? PartnerName { get; set; }
    public string? PartnerPhone { get; set; }
    public string? PartnerEmail { get; set; }
    public int TargetMinutes { get; set; } = 30;
    /// <summary>Hospital Settings > LAB > Critical Value Communication Required for the branch (off = approval as before).</summary>
    public bool CommunicationEnabled { get; set; }
}

/// <summary>One communication record (RS3), corrected ones included.</summary>
public class LabCriticalHistoryDto
{
    public long CommunicationId { get; set; }
    public long SampleId { get; set; }
    public string? Outcome { get; set; }
    public string? InformedName { get; set; }
    public string? InformedRole { get; set; }
    public string? ContactNo { get; set; }
    public string? Mode { get; set; }
    public DateTime InformedOn { get; set; }
    public bool ReadBack { get; set; }
    public string? Remarks { get; set; }
    public string? ResultValue { get; set; }
    public string? Source { get; set; }
    public bool IsActive { get; set; }
    public long? CorrectsId { get; set; }
    public string? MessageStatus { get; set; }
    public string? MessageError { get; set; }
    public string? RecordedBy { get; set; }
    public DateTime RecordedOn { get; set; }
}

public class LabCriticalPendingResult
{
    public List<LabCriticalResultDto> Results { get; set; } = new();
    public LabCriticalContactsDto? Contacts { get; set; }
    public List<LabCriticalHistoryDto> History { get; set; } = new();
}

public class LabCriticalRecordItem
{
    public long SampleId { get; set; }
    public string? Outcome { get; set; }
    public string? InformedName { get; set; }
    public string? InformedRole { get; set; }
    public string? ContactNo { get; set; }
    public string? Mode { get; set; }
    public DateTime? InformedOn { get; set; }
    public bool ReadBack { get; set; }
    public string? Remarks { get; set; }
    public long? CorrectsId { get; set; }
    /// <summary>Send the WhatsApp message / email from the application (existing branch configuration).</summary>
    public bool SendMessage { get; set; }
}

public class LabCriticalRecordRequest
{
    public int BranchId { get; set; }
    public int LabOrderId { get; set; }
    public string? Source { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
    public List<LabCriticalRecordItem> Items { get; set; } = new();
}

/// <summary>A record written by dbo.usp_LabCritical_Record.</summary>
public class LabCriticalRecordedDto
{
    public long CommunicationId { get; set; }
    public long SampleId { get; set; }
    public string? TestName { get; set; }
    public string? ResultValue { get; set; }
    public string? Unit { get; set; }
    public string? Severity { get; set; }
    public string? Outcome { get; set; }
    public string? InformedName { get; set; }
    public string? InformedRole { get; set; }
    public string? ContactNo { get; set; }
    public string? Mode { get; set; }
    public DateTime InformedOn { get; set; }
    public bool ReadBack { get; set; }
    public string? Remarks { get; set; }
    public long? CorrectsId { get; set; }
    public string? MessageStatus { get; set; }
}
