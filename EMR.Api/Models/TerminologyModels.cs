namespace EMR.Api.Models;

// Utility > API data: Standard Laboratory Test Master (LOINC), SQLScripts/2316.

public class TermReleaseRow
{
    public int ReleaseId { get; set; }
    public string SystemCode { get; set; } = "";
    public string VersionCode { get; set; } = "";
    public DateTime? ReleaseDate { get; set; }
    public DateTime ImportedAt { get; set; }
    public string Status { get; set; } = "";
    public bool IsActive { get; set; }
    public string? SourceFileName { get; set; }
    public string? SourceFileHash { get; set; }
    public string? Notes { get; set; }
    public DateTime? PublishedAt { get; set; }
    public string? PublishedByName { get; set; }
    public int? ImportJobId { get; set; }
    public string? JobStatus { get; set; }
    public int? RowsRead { get; set; }
    public int? RowsStaged { get; set; }
    public int? RowsError { get; set; }
    public int? CountAdded { get; set; }
    public int? CountModified { get; set; }
    public int? CountRetired { get; set; }
    public int? CountUnchanged { get; set; }
    public string? JobMessage { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? FinishedAt { get; set; }
    public long? FileSizeBytes { get; set; }
    public int ConceptsFromRelease { get; set; }
}

public class TermRepositoryStats
{
    public int Concepts { get; set; }
    public int? ActiveConcepts { get; set; }
    public int? LabConcepts { get; set; }
    public string? ActiveVersion { get; set; }
    public int ApprovedMappings { get; set; }
    public int PendingMappings { get; set; }
    public int ReviewMappings { get; set; }
}

public class TermReleasesResult
{
    public List<TermReleaseRow> Releases { get; set; } = [];
    public TermRepositoryStats Stats { get; set; } = new();
    public bool OnlineConfigured { get; set; }
}

public class TermImportJob
{
    public int ImportJobId { get; set; }
    public int ReleaseId { get; set; }
    public string Status { get; set; } = "";
    public string? SourceFileName { get; set; }
    public string? SourceFileHash { get; set; }
    public long? FileSizeBytes { get; set; }
    public string? EntryName { get; set; }
    public int RowsRead { get; set; }
    public int RowsStaged { get; set; }
    public int RowsError { get; set; }
    public int? CountAdded { get; set; }
    public int? CountModified { get; set; }
    public int? CountRetired { get; set; }
    public int? CountUnchanged { get; set; }
    public string? Message { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? FinishedAt { get; set; }
    public string VersionCode { get; set; } = "";
    public DateTime? ReleaseDate { get; set; }
    public string ReleaseStatus { get; set; } = "";
    public bool IsActive { get; set; }
    public int CriticalErrors { get; set; }
    public int Warnings { get; set; }
}

public class TermImportError
{
    public long ImportErrorId { get; set; }
    public string? FileName { get; set; }
    public int? RowNumber { get; set; }
    public string? LoincCode { get; set; }
    public string Severity { get; set; } = "";
    public string Reason { get; set; } = "";
}

public class TermPaged<T>
{
    public int TotalCount { get; set; }
    public int Page { get; set; }
    public int PageSize { get; set; }
    public List<T> Items { get; set; } = [];
}

public class TermStartImportRequest
{
    public string UploadId { get; set; } = "";
    public string FileName { get; set; } = "";
    public string VersionCode { get; set; } = "";
    public DateTime? ReleaseDate { get; set; }
    public string? Notes { get; set; }
    public int? UserId { get; set; }
}

public class TermUserRequest
{
    public int? UserId { get; set; }
}

public class LoincConceptRow
{
    public string LoincCode { get; set; } = "";
    public string? LongCommonName { get; set; }
    public string? ShortName { get; set; }
    public string? Component { get; set; }
    public string? Property { get; set; }
    public string? TimeAspect { get; set; }
    public string? SystemName { get; set; }
    public string? ScaleType { get; set; }
    public string? MethodName { get; set; }
    public string? ClassName { get; set; }
    public string? ClassType { get; set; }
    public string? Status { get; set; }
    public string? OrderObs { get; set; }
    public string? ExampleUcumUnits { get; set; }
    public string? ExampleUnits { get; set; }
    public string? VersionLastChanged { get; set; }
    public string? SourceVersion { get; set; }
    public bool IsRetired { get; set; }
    public int ApprovedMappings { get; set; }
    public int PendingMappings { get; set; }
    public string? FirstVersion { get; set; }
    public string? LastChangedVersion { get; set; }
    /// <summary>Online results: already in the local repository.</summary>
    public bool InLocal { get; set; }
}

public class LoincConceptMappingRef
{
    public long MappingId { get; set; }
    public int InvestigationId { get; set; }
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string MappingStatus { get; set; } = "";
    public bool IsPreferred { get; set; }
    public bool NeedsReview { get; set; }
}

public class LoincConceptHistory
{
    public string VersionCode { get; set; } = "";
    public string ChangeType { get; set; } = "";
    public string? ChangedFields { get; set; }
    public string? OldStatus { get; set; }
    public string? NewStatus { get; set; }
}

public class LoincConceptDetail
{
    public LoincConceptRow? Concept { get; set; }
    public List<LoincConceptMappingRef> Mappings { get; set; } = [];
    public List<LoincConceptHistory> History { get; set; } = [];
}

public class LoincClassRow
{
    public string ClassName { get; set; } = "";
    public int Concepts { get; set; }
}

public class TermOnlineResult
{
    public bool Configured { get; set; }
    public bool Success { get; set; }
    public string? Message { get; set; }
    public int TotalFound { get; set; }
    public List<LoincConceptRow> Items { get; set; } = [];
}

public class TermSaveLookupRequest
{
    public LoincConceptRow Concept { get; set; } = new();
    public int? UserId { get; set; }
}

public class TermChangeRow
{
    public long ReleaseChangeId { get; set; }
    public string LoincCode { get; set; } = "";
    public string ChangeType { get; set; } = "";
    public string? OldStatus { get; set; }
    public string? NewStatus { get; set; }
    public string? OldName { get; set; }
    public string? NewName { get; set; }
    public string? ChangedFields { get; set; }
    public int LocalMappings { get; set; }
}

public class TermChangesResult
{
    public Dictionary<string, int> Counts { get; set; } = new();
    public TermPaged<TermChangeRow> Page { get; set; } = new();
}

public class TermInvestigationRow
{
    public int InvestigationId { get; set; }
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string DepartmentName { get; set; } = "";
    public string CategoryName { get; set; } = "";
    public string SampleName { get; set; } = "";
    public string ContainerType { get; set; } = "";
    public string? UnitName { get; set; }
    public bool IsProfile { get; set; }
    public bool IsActive { get; set; }
    public int Approved { get; set; }
    public int Pending { get; set; }
    public int Review { get; set; }
    public string? PreferredLoinc { get; set; }
}

public class TermInvestigationKpis
{
    public int Total { get; set; }
    public int? Mapped { get; set; }
    public int? PendingOnly { get; set; }
    public int? Unmapped { get; set; }
    public int? NeedReview { get; set; }
}

public class TermDeptOption
{
    public int DeptId { get; set; }
    public string DeptName { get; set; } = "";
}

public class TermInvestigationsResult
{
    public TermInvestigationKpis Kpis { get; set; } = new();
    public TermPaged<TermInvestigationRow> Page { get; set; } = new();
    public List<TermDeptOption> Departments { get; set; } = [];
}

public class TermMappingRow
{
    public long MappingId { get; set; }
    public string LoincCode { get; set; } = "";
    public string? LongCommonName { get; set; }
    public string? Component { get; set; }
    public string? SystemName { get; set; }
    public string? ScaleType { get; set; }
    public string? MethodName { get; set; }
    public string? ExampleUcumUnits { get; set; }
    public string? ConceptStatus { get; set; }
    public bool IsRetired { get; set; }
    public string MappingStatus { get; set; } = "";
    public string MappingMethod { get; set; } = "";
    public bool IsPreferred { get; set; }
    public bool NeedsReview { get; set; }
    public string? ReviewReason { get; set; }
    public string? Notes { get; set; }
    public DateTime ProposedAt { get; set; }
    public string? ProposedByName { get; set; }
    public int? ProposedBy { get; set; }
    public DateTime? ApprovedAt { get; set; }
    public string? ApprovedByName { get; set; }
    public string? DecisionNote { get; set; }
}

public class TermMappingAuditRow
{
    public DateTime At { get; set; }
    public string Action { get; set; } = "";
    public string LoincCode { get; set; } = "";
    public string? FromStatus { get; set; }
    public string? ToStatus { get; set; }
    public string? Note { get; set; }
    public string? UserName { get; set; }
}

public class TermSuggestionRow
{
    public string LoincCode { get; set; } = "";
    public string? LongCommonName { get; set; }
    public string? Component { get; set; }
    public string? SystemName { get; set; }
    public string? ScaleType { get; set; }
    public string? MethodName { get; set; }
    public string? ExampleUcumUnits { get; set; }
    public string? Status { get; set; }
    public int Hits { get; set; }
    public int SystemMatch { get; set; }
}

public class TermInvestigationDetail
{
    public TermInvestigationRow? Investigation { get; set; }
    public List<TermMappingRow> Mappings { get; set; } = [];
    public List<TermMappingAuditRow> Audit { get; set; } = [];
    public List<TermSuggestionRow> Suggestions { get; set; } = [];
}

public class TermProposeRequest
{
    public string LoincCode { get; set; } = "";
    public string? Method { get; set; }
    public string? Notes { get; set; }
    public int? UserId { get; set; }
    public int? CompanyId { get; set; }
}

public class TermDecideRequest
{
    public string Decision { get; set; } = "";
    public string? Note { get; set; }
    public int? UserId { get; set; }
}
