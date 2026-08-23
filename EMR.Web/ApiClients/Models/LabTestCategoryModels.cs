namespace EMR.Web.ApiClients.Models;

public class LabTestCategoryModel
{
    public int Category_ID { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int Department_ID { get; set; }
    public string Department_Name { get; set; } = string.Empty;
    public string Department_Code { get; set; } = string.Empty;
    public string Category_Name { get; set; } = string.Empty;
    public string Category_Code { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabTestCategoryCreateRequestModel
{
    public int Department_ID { get; set; }
    public string Category_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int BranchId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabTestCategoryUpdateRequestModel
{
    public int Category_ID { get; set; }
    public int Department_ID { get; set; }
    public string Category_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabTestCategoryToggleStatusRequestModel
{
    public int Category_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
