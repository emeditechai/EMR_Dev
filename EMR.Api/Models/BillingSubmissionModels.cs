namespace EMR.Api.Models;

/// <summary>One bill per booking (SQLScripts/2310): claim a booking request key before creating the bill.</summary>
public class BillingSubmissionClaimRequest
{
    public Guid RequestKey { get; set; }
    public string ModuleCode { get; set; } = "";
    public int? UserId { get; set; }
}

/// <summary>NEW / EXISTS / BUSY / INVALID, and the bill already created for the key (EXISTS).</summary>
public class BillingSubmissionClaimResult
{
    public string Status { get; set; } = "NEW";
    public int? ModuleRefId { get; set; }
    public string? BillNo { get; set; }
    public int? PatientId { get; set; }
    public string? ItemsSignature { get; set; }
    public string? Stage { get; set; }
    public bool HasPayment { get; set; }
    public string? TokenNo { get; set; }
}

public class BillingSubmissionUpdateRequest
{
    public Guid RequestKey { get; set; }
    public int ModuleRefId { get; set; }
    public string? BillNo { get; set; }
    public int? PatientId { get; set; }
    public string? ItemsSignature { get; set; }
    public string Stage { get; set; } = "CREATED";
}

public class BillingSubmissionReleaseRequest
{
    public Guid RequestKey { get; set; }
}
