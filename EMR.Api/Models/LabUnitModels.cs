namespace EMR.Api.Models;

public class LabUnitListItem
{
    public int Unit_ID { get; set; }
    public int CompanyId { get; set; }
    public string Unit_Name { get; set; } = string.Empty;
    public string Unit_Code { get; set; } = string.Empty;
    public string? Unit_Symbol { get; set; }
    public decimal Conversion_Factor { get; set; } = 1.0m;
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabUnitCreateRequest
{
    public string Unit_Name { get; set; } = string.Empty;
    public string? Unit_Symbol { get; set; }
    public decimal Conversion_Factor { get; set; } = 1.0m;
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabUnitUpdateRequest
{
    public int Unit_ID { get; set; }
    public string Unit_Name { get; set; } = string.Empty;
    public string? Unit_Symbol { get; set; }
    public decimal Conversion_Factor { get; set; } = 1.0m;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabUnitToggleStatusRequest
{
    public int Unit_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
