namespace EMR.Api.Models;

/// <summary>One configured report signatory level (1..3) of a branch.</summary>
public class LabDefaultSignatoryDto
{
    public int SignatoryId { get; set; }
    public int LevelNo { get; set; }
    public int UserId { get; set; }
    public string? SignaturePath { get; set; }
    public bool IsActive { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    /// <summary>The signature on the user's own profile, used when the level has no override.</summary>
    public string? UserSignaturePath { get; set; }
    public bool IsEligible { get; set; }
}

/// <summary>A pathologist of the branch that can be picked as a signatory.</summary>
public class LabSignatoryCandidateDto
{
    public int UserId { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    public string? SignaturePath { get; set; }
    public bool HasSignature { get; set; }
}

public class LabDefaultSignatoryListResult
{
    public List<LabDefaultSignatoryDto> Signatories { get; set; } = [];
    public List<LabSignatoryCandidateDto> Candidates { get; set; } = [];
}

public class LabDefaultSignatoryItem
{
    public int LevelNo { get; set; }
    public int UserId { get; set; }
    public string? SignaturePath { get; set; }
}

public class LabDefaultSignatorySaveRequest
{
    public int BranchId { get; set; }
    public int CompanyId { get; set; } = 1;
    public int UserId { get; set; }
    public List<LabDefaultSignatoryItem> Items { get; set; } = [];
}
