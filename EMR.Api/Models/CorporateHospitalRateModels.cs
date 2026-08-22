namespace EMR.Api.Models;

public class CorporateHospitalRateListItemDto
{
    public int CorpRate_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int Corporate_ID { get; set; }
    public string Corporate_Name { get; set; } = string.Empty;
    public string? Corporate_Code { get; set; }
    public string RateServiceType { get; set; } = string.Empty; // Room, Procedure, OT, ICU, HospitalService, Package
    public int ReferenceMaster_ID { get; set; }
    public string RateType { get; set; } = "Percentage"; // Percentage, Rate, Both
    public decimal? Rate { get; set; }
    public decimal? DiscountPercent { get; set; }
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

public class CorporateHospitalRateDetailDto : CorporateHospitalRateListItemDto
{
}

public class CorporateHospitalRateSaveRequest
{
    public int? CorpRate_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public int Corporate_ID { get; set; }
    public string RateServiceType { get; set; } = "Procedure"; // Room, Procedure, OT, ICU, HospitalService, Package
    public int ReferenceMaster_ID { get; set; }
    public string RateType { get; set; } = "Percentage"; // Percentage, Rate, Both
    public decimal? Rate { get; set; }
    public decimal? DiscountPercent { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime Effective_To { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class MasterServiceItemDto
{
    public string RateServiceType { get; set; } = string.Empty;
    public int ReferenceMaster_ID { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal BaseRate { get; set; }
}
