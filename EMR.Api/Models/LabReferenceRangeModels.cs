namespace EMR.Api.Models;

public class LabReferenceRangeListItem
{
    public int RefRange_ID { get; set; }
    public int CompanyId { get; set; }
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public int? Method_ID { get; set; }
    public string? Method_Name { get; set; }
    public int Unit_ID { get; set; }
    public string Unit_Name { get; set; } = string.Empty;
    public string? Unit_Symbol { get; set; }
    public decimal Age_From { get; set; }
    public decimal Age_To { get; set; }
    public string Age_Unit { get; set; } = "Years";
    public string Gender { get; set; } = "All";
    public string Pregnancy_Trimester { get; set; } = "Not Applicable";
    public decimal? Low_Value { get; set; }
    public decimal? High_Value { get; set; }
    public string? Special_Remarks { get; set; }
    public string? Range_Source { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime? Effective_To { get; set; }
    public bool Status { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabReferenceRangeDetail : LabReferenceRangeListItem
{
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }
}

public class LabReferenceRangeCreateRequest
{
    public int CompanyId { get; set; } = 1;
    public int Test_ID { get; set; }
    public int? Method_ID { get; set; }
    public int Unit_ID { get; set; }
    public decimal Age_From { get; set; }
    public decimal Age_To { get; set; }
    public string Age_Unit { get; set; } = "Years";
    public string Gender { get; set; } = "All";
    public string Pregnancy_Trimester { get; set; } = "Not Applicable";
    public decimal? Low_Value { get; set; }
    public decimal? High_Value { get; set; }
    public string? Special_Remarks { get; set; }
    public string? Range_Source { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime? Effective_To { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabReferenceRangeUpdateRequest
{
    public int RefRange_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Test_ID { get; set; }
    public int? Method_ID { get; set; }
    public int Unit_ID { get; set; }
    public decimal Age_From { get; set; }
    public decimal Age_To { get; set; }
    public string Age_Unit { get; set; } = "Years";
    public string Gender { get; set; } = "All";
    public string Pregnancy_Trimester { get; set; } = "Not Applicable";
    public decimal? Low_Value { get; set; }
    public decimal? High_Value { get; set; }
    public string? Special_Remarks { get; set; }
    public string? Range_Source { get; set; }
    public DateTime Effective_From { get; set; }
    public DateTime? Effective_To { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabReferenceRangeToggleStatusRequest
{
    public int RefRange_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabNumericTestOption
{
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public string Reporting_Type { get; set; } = string.Empty;
    public int? Method_ID { get; set; }
    public string? Method_Name { get; set; }
    public int? Unit_ID { get; set; }
    public string? Unit_Name { get; set; }
    public string? Unit_Symbol { get; set; }
    public string? Applicable_Gender { get; set; }
}
