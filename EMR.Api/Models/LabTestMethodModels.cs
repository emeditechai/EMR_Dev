namespace EMR.Api.Models;

public class LabTestMethodListItem
{
    public int Method_ID { get; set; }
    public int CompanyId { get; set; }
    public int Department_ID { get; set; }
    public string Department_Name { get; set; } = string.Empty;
    public string Department_Code { get; set; } = string.Empty;
    public string Method_Name { get; set; } = string.Empty;
    public string Method_Code { get; set; } = string.Empty;
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabTestMethodCreateRequest
{
    public int Department_ID { get; set; }
    public string Method_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabTestMethodUpdateRequest
{
    public int Method_ID { get; set; }
    public int Department_ID { get; set; }
    public string Method_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabTestMethodToggleStatusRequest
{
    public int Method_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
