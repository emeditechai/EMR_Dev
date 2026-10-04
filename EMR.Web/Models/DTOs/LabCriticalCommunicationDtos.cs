namespace EMR.Web.Models.DTOs;

/// <summary>One communication posted from the critical value form (wwwroot/js/critical-communication.js).</summary>
public class LabCriticalRecordItemDto
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
    public bool SendMessage { get; set; }
}

public class LabCriticalRecordRequestDto
{
    public int BranchId { get; set; }
    public int LabOrderId { get; set; }
    public string? Source { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
    public List<LabCriticalRecordItemDto> Items { get; set; } = new();
}

/// <summary>A record written by the API (dbo.usp_LabCritical_Record).</summary>
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
