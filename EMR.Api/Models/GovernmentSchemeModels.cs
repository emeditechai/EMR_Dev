namespace EMR.Api.Models;

public class GovernmentSchemeListItemDto
{
    public int Scheme_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string SchemeCode { get; set; } = string.Empty;
    public string SchemeName { get; set; } = string.Empty;
    public string SchemeType { get; set; } = string.Empty; // Central Government, State Government, Defence / Ex-Servicemen, PSU / Autonomous Body, Social Security / Labour
    public string AuthorityName { get; set; } = string.Empty;
    public string? RuleConfigJSON { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class GovernmentSchemeDetailDto : GovernmentSchemeListItemDto
{
}

public class GovernmentSchemeSaveRequest
{
    public int? Scheme_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string SchemeCode { get; set; } = string.Empty;
    public string SchemeName { get; set; } = string.Empty;
    public string SchemeType { get; set; } = "Central Government";
    public string AuthorityName { get; set; } = string.Empty;
    public string? RuleConfigJSON { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool IsActive { get; set; } = true;
    public int? UserId { get; set; }
}
