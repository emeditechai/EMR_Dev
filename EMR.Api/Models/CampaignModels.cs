namespace EMR.Api.Models;

// Utility > Campaigns (SQLScripts/2299): api/campaigns over the usp_Campaign_* procedures.

/// <summary>Who a campaign goes to. Mode ALL, FILTER or PICK (Ids).</summary>
public class CampaignAudienceFilter
{
    public string Mode { get; set; } = "ALL";
    public int? BranchId { get; set; }
    public string? Gender { get; set; }
    public int? AgeFrom { get; set; }
    public int? AgeTo { get; set; }
    public DateTime? VisitFrom { get; set; }
    public DateTime? VisitTo { get; set; }
    public DateTime? RegisteredFrom { get; set; }
    public DateTime? RegisteredTo { get; set; }
    public int? RoleId { get; set; }
    public int? SpecialityId { get; set; }
    public string? DoctorKind { get; set; }
    public List<int> Ids { get; set; } = [];
}

public class CampaignPersonDto
{
    public int RefId { get; set; }
    public string? Name { get; set; }
    public string? FirstName { get; set; }
    public string? Email { get; set; }
    public string? Code { get; set; }
    public string? Phone { get; set; }
    public string? Extra { get; set; }
    public bool OptedOut { get; set; }
}

public class CampaignAudienceRequest
{
    public int CompanyId { get; set; }
    public string AudienceType { get; set; } = "P";
    public CampaignAudienceFilter Filter { get; set; } = new();
}

/// <summary>What a selection covers: everyone, who can get the email, and why the others cannot.</summary>
public class CampaignAudienceSummary
{
    public int Total { get; set; }
    public int Reachable { get; set; }
    public int NoEmail { get; set; }
    public int Unsubscribed { get; set; }
    public int SharedEmail { get; set; }
    public List<CampaignPersonDto> Sample { get; set; } = [];
}

public class CampaignRowDto
{
    public int CampaignId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Channel { get; set; } = "EMAIL";
    public string Status { get; set; } = "";
    public string Subject { get; set; } = "";
    public DateTime CreatedDate { get; set; }
    public DateTime? ScheduledAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public string? CreatedByName { get; set; }
    public int Total { get; set; }
    public int Sent { get; set; }
    public int Failed { get; set; }
    public int Skipped { get; set; }
    public int Pending { get; set; }
}

public class CampaignDetailDto : CampaignRowDto
{
    public string DesignJson { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public string SelectionMode { get; set; } = "ALL";
    public string? FilterJson { get; set; }
    public int? TemplateId { get; set; }
    public string? HospitalName { get; set; }
    public string? SenderEmail { get; set; }
}

public class CampaignTemplateRowDto
{
    public int TemplateId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int Used { get; set; }
}

public class CampaignListResult
{
    public List<CampaignRowDto> Campaigns { get; set; } = [];
    public List<CampaignTemplateRowDto> Templates { get; set; } = [];
}

public class CampaignBranchOption
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public bool IsHo { get; set; }
    public string? SenderEmail { get; set; }
    public string? HospitalName { get; set; }
}

public class CampaignOption
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
}

public class CampaignOptionsResult
{
    public List<CampaignBranchOption> Branches { get; set; } = [];
    public List<CampaignOption> Roles { get; set; } = [];
    public List<CampaignOption> Specialities { get; set; } = [];
}

/// <summary>Save a draft, or send now / schedule (the recipients are fixed then).</summary>
public class CampaignSaveRequest
{
    public int CampaignId { get; set; }
    public int CompanyId { get; set; }
    /// <summary>The "send from" branch: its mail settings send the emails.</summary>
    public int BranchId { get; set; }
    public int UserId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public int? TemplateId { get; set; }
    public string Subject { get; set; } = "";
    public string DesignJson { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public CampaignAudienceFilter Filter { get; set; } = new();
    public string? BaseUrl { get; set; }
    /// <summary>draft, send or schedule.</summary>
    public string Action { get; set; } = "draft";
    public DateTime? ScheduledAt { get; set; }
}

public class CampaignSaveResult
{
    public int CampaignId { get; set; }
    public int Queued { get; set; }
    public int Skipped { get; set; }
}

public class CampaignRecipientDto
{
    public string? Name { get; set; }
    public string? Email { get; set; }
    public string Status { get; set; } = "P";
    public string? Message { get; set; }
    public DateTime? SentAt { get; set; }
    public int Attempts { get; set; }
}

public class CampaignActionRequest
{
    public int CampaignId { get; set; }
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    /// <summary>CANCEL, RETRY or DELETE.</summary>
    public string Action { get; set; } = "";
}

public class CampaignTemplateDto
{
    public int TemplateId { get; set; }
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public string DesignJson { get; set; } = "";
    public bool IsActive { get; set; } = true;
}

// ── the sender (EMR.Web background service, service token) ──
public class CampaignRunningDto
{
    public int CampaignId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public string? BaseUrl { get; set; }
    public string HospitalName { get; set; } = "";
}

public class CampaignPendingDto
{
    public long RecipientId { get; set; }
    public string? Email { get; set; }
    public string? FieldsJson { get; set; }
}

public class CampaignMarkRequest
{
    public long RecipientId { get; set; }
    /// <summary>S sent, F failed.</summary>
    public string Status { get; set; } = "S";
    public string? Message { get; set; }
}

public class CampaignOptOutRequest
{
    public int CompanyId { get; set; }
    public int? CampaignId { get; set; }
    public string Email { get; set; } = "";
}
