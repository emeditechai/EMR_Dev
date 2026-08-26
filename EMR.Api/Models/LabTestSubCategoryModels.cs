namespace EMR.Api.Models;

public class LabTestSubCategoryListItem
{
    public int SubCategory_ID { get; set; }
    public int CompanyId { get; set; }
    public int Category_ID { get; set; }
    public string Category_Name { get; set; } = string.Empty;
    public string Category_Code { get; set; } = string.Empty;
    public int Department_ID { get; set; }
    public string Department_Name { get; set; } = string.Empty;
    public string Department_Code { get; set; } = string.Empty;
    public string SubCategory_Name { get; set; } = string.Empty;
    public string SubCategory_Code { get; set; } = string.Empty;
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabTestSubCategoryCreateRequest
{
    public int Category_ID { get; set; }
    public string SubCategory_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabTestSubCategoryUpdateRequest
{
    public int SubCategory_ID { get; set; }
    public int Category_ID { get; set; }
    public string SubCategory_Name { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabTestSubCategoryToggleStatusRequest
{
    public int SubCategory_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
