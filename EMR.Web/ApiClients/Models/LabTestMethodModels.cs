namespace EMR.Web.ApiClients.Models;

public class LabTestMethodModel
{
    public int Method_ID { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int Department_ID { get; set; }
    public string Department_Name { get; set; } = string.Empty;
    public string Department_Code { get; set; } = string.Empty;
    public string Method_Name { get; set; } = string.Empty;
    public string Method_Code { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabTestMethodCreateRequestModel
{
    public int Department_ID { get; set; }
    public string Method_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int BranchId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabTestMethodUpdateRequestModel
{
    public int Method_ID { get; set; }
    public int Department_ID { get; set; }
    public string Method_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabTestMethodToggleStatusRequestModel
{
    public int Method_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
