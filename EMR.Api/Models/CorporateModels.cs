namespace EMR.Api.Models;

public class CorporateListItemDto
{
    public int Corporate_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string? Corporate_Code { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string Corporate_Type { get; set; } = string.Empty;
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public decimal? Credit_Limit { get; set; }
    public int? Credit_Days { get; set; }
    public string BillingCycle { get; set; } = string.Empty;
    public string Contact_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class CorporateDetailDto : CorporateListItemDto
{
}

public class CorporateSaveRequest
{
    public int? Corporate_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string? Corporate_Code { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string Corporate_Type { get; set; } = "ALL";
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public decimal? Credit_Limit { get; set; }
    public int? Credit_Days { get; set; }
    public string BillingCycle { get; set; } = "Monthly";
    public string Contact_No { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}
