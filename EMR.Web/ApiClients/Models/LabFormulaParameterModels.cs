namespace EMR.Web.ApiClients.Models;

public class LabFormulaParameterModel
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

public class LabFormulaParameterCreateRequestModel
{
    public int Test_ID { get; set; }
    public string Formula_Expression { get; set; } = string.Empty;
    public int Rounding_Precision { get; set; } = 2;
    public string? Validity_Condition { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabFormulaParameterUpdateRequestModel
{
    public int Parameter_ID { get; set; }
    public int Test_ID { get; set; }
    public string Formula_Expression { get; set; } = string.Empty;
    public int Rounding_Precision { get; set; } = 2;
    public string? Validity_Condition { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class LabFormulaParameterToggleStatusRequestModel
{
    public int Parameter_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class NumericTestItemModel
{
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
}
