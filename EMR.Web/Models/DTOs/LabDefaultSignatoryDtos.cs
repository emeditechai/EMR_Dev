namespace EMR.Web.Models.DTOs;

/// <summary>One configured report signatory — a single pathologist slot within a department of a branch.</summary>
public class LabDefaultSignatoryDto
{
    public int SignatoryId { get; set; }
    public int DepartmentId { get; set; }
    public int SlotNo { get; set; }        // 1, 2 or 3 within the department
    public int UserId { get; set; }
    public string? SignaturePath { get; set; }
    public bool IsActive { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    /// <summary>The signature on the user's own profile, used when no override is stored.</summary>
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

public class LabDepartmentDto
{
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
}

public class LabDefaultSignatoryListResult
{
    public List<LabDefaultSignatoryDto> Signatories { get; set; } = [];
    public List<LabSignatoryCandidateDto> Candidates { get; set; } = [];
    public List<LabDepartmentDto> Departments { get; set; } = [];
}

public class LabDefaultSignatoryItem
{
    public int DepartmentId { get; set; }
    public int SlotNo { get; set; }        // 1, 2 or 3 within the department
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
