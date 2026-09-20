namespace EMR.Api.Models;

public class LabReportingConditionModel
{
    public int Condition_ID { get; set; }
    public int CompanyId { get; set; }
    /// <summary>Null = company-wide (applies to every branch of the company).</summary>
    public int? Branch_ID { get; set; }
    public string? Branch_Name { get; set; }
    public string? Branch_Code { get; set; }
    public string Condition_Code { get; set; } = string.Empty;
    public string Condition_Text { get; set; } = string.Empty;
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabReportingConditionCreateRequestModel
{
    public string Condition_Text { get; set; } = string.Empty;
    public int? Branch_ID { get; set; }
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabReportingConditionUpdateRequestModel
{
    public int Condition_ID { get; set; }
    public string Condition_Text { get; set; } = string.Empty;
    public int? Branch_ID { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabReportingConditionToggleStatusRequestModel
{
    public int Condition_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

/// <summary>What the Lab Report PDF prints on its Conditions of Reporting page.</summary>
public class LabReportConditionsForReportModel
{
    /// <summary>False when the company has never configured any condition (the report then uses its built-in text).</summary>
    public bool HasConfiguration { get; set; }
    public List<string> Conditions { get; set; } = new();
}
