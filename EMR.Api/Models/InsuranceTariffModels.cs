namespace EMR.Api.Models;

public class InsuranceTariffListItemDto
{
    public int InsTariff_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int InsuranceTPA_ID { get; set; }
    public string InsuranceTPAName { get; set; } = string.Empty;
    public string? InsuranceTPACode { get; set; }
    public string? InsuranceTPAType { get; set; }
    public string EntitlementType { get; set; } = string.Empty; // Room, Package, Procedure, HospitalService, NonPayableItem
    public int Reference_ID { get; set; }
    public string DeductionRuleType { get; set; } = "None"; // None, Fixed Deduction, Percentage Co-Pay, Proportional Capping, Non-Payable Item, Agreed Tariff Cap
    public decimal DeductionValue { get; set; }
    public decimal Rate { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Resolved dynamic master values
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }
    public decimal StandardBaseRate { get; set; }
}

public class InsuranceTariffDetailDto : InsuranceTariffListItemDto
{
}

public class InsuranceTariffSaveRequest
{
    public int? InsTariff_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public int InsuranceTPA_ID { get; set; }
    public string EntitlementType { get; set; } = "Procedure"; // Room, Package, Procedure, HospitalService, NonPayableItem
    public int Reference_ID { get; set; }
    public string DeductionRuleType { get; set; } = "Standard Tariff";
    public decimal DeductionValue { get; set; }
    public decimal Rate { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class InsuranceMasterServiceItemDto
{
    public string EntitlementType { get; set; } = string.Empty;
    public int Reference_ID { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal BaseRate { get; set; }
}
