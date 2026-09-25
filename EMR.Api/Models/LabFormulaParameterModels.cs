namespace EMR.Api.Models;

public class LabFormulaParameterListItem
{
    public int Parameter_ID { get; set; }
    public int Test_ID { get; set; }
    public string Test_Name { get; set; } = string.Empty;
    public string Test_Code { get; set; } = string.Empty;
    public string Formula_Expression { get; set; } = string.Empty;
    public int Rounding_Precision { get; set; }
    public string? Validity_Condition { get; set; }
    public bool IsActive { get; set; }
    public int CompanyId { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabFormulaParameterCreateRequest
{
    public int Test_ID { get; set; }
    public string Formula_Expression { get; set; } = string.Empty;
    public int Rounding_Precision { get; set; } = 2;
    public string? Validity_Condition { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabFormulaParameterUpdateRequest
{
    public int Parameter_ID { get; set; }
    public int Test_ID { get; set; }
    public string Formula_Expression { get; set; } = string.Empty;
    public int Rounding_Precision { get; set; } = 2;
    public string? Validity_Condition { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class LabFormulaParameterToggleStatusRequest
{
    public int Parameter_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class NumericTestItem
{
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
}

/// <summary>A formula configured for a test that is on the lab order being reported (script 2129).</summary>
public class LabFormulaForOrderItem
{
    public int Parameter_ID { get; set; }
    public int TargetTestId { get; set; }
    public string TargetTestCode { get; set; } = string.Empty;
    public string TargetTestName { get; set; } = string.Empty;
    public string FormulaExpression { get; set; } = string.Empty;
    public int RoundingPrecision { get; set; }
    public string? ValidityCondition { get; set; }
}

public class LabFormulaEvaluateRequest
{
    public int LabOrderId { get; set; }
    public int? CompanyId { get; set; }
    /// <summary>What the technician has entered so far: test code -> value as typed.</summary>
    public List<LabFormulaEntryValue> Values { get; set; } = new();
}

public class LabFormulaEntryValue
{
    public string TestCode { get; set; } = string.Empty;
    public string? Value { get; set; }
}

/// <summary>One calculated parameter, worked out on the server from its configured formula.</summary>
public class LabFormulaEvaluationResult
{
    public int Parameter_ID { get; set; }
    public string TargetTestCode { get; set; } = string.Empty;
    public string TargetTestName { get; set; } = string.Empty;
    public string FormulaExpression { get; set; } = string.Empty;
    public int RoundingPrecision { get; set; }
    public string? ValidityCondition { get; set; }
    /// <summary>The rounded value to show, or null when it cannot be calculated yet.</summary>
    public string? Value { get; set; }
    /// <summary>Why there is no value: missing inputs, divide by zero, or a formula that is not valid.</summary>
    public string? Message { get; set; }
    public List<string> UsedCodes { get; set; } = new();
    public List<string> MissingCodes { get; set; } = new();
}
