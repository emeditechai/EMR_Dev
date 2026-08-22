namespace EMR.Api.Models;

public class InsuranceTPAListItemDto
{
    public int InsuranceTPA_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Type { get; set; } = string.Empty; // 'Insurance Company', 'TPA'
    public string Name { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public string? SchemeName { get; set; }
    public string PolicyPrefix { get; set; } = string.Empty;
    public string NetworkCategory { get; set; } = string.Empty; // 'Cashless', 'Reimbursement', 'Both'
    public bool AuthorizationRequired { get; set; }
    public string? ContactPerson { get; set; }
    public string? ContactNumber { get; set; }
    public string? Email { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class InsuranceTPADetailDto : InsuranceTPAListItemDto
{
}

public class InsuranceTPASaveRequest
{
    public int? InsuranceTPA_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string Type { get; set; } = "Insurance Company";
    public string Name { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public string? SchemeName { get; set; }
    public string? PolicyPrefix { get; set; }
    public string NetworkCategory { get; set; } = "Both";
    public bool AuthorizationRequired { get; set; } = true;
    public string? ContactPerson { get; set; }
    public string? ContactNumber { get; set; }
    public string? Email { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}
