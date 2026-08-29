namespace EMR.Web.ApiClients.Models;

public class LabInvestigationProfileHeaderModel
{
    public int Profile_ID { get; set; }
    public int CompanyId { get; set; }
    public string Profile_Code { get; set; } = string.Empty;
    public string Profile_Name { get; set; } = string.Empty;
    public string Profile_Type { get; set; } = "Profile";
    public int? Test_ID { get; set; }
    public string? ProfileTestCode { get; set; }
    public string? ProfileTestName { get; set; }
    public decimal MRP { get; set; }
    public decimal Discount_Pct { get; set; }
    public string? Age_Operator { get; set; }
    public int? Applicable_Age { get; set; }
    public string Applicable_Gender { get; set; } = "All";
    public int Profile_TAT_Hours { get; set; }
    public bool Profile_NABL_Accredited { get; set; }
    public int Report_Print_Sequence { get; set; }
    public bool Status { get; set; }
    public int TestCount { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabInvestigationProfileDetailModel
{
    public int Detail_ID { get; set; }
    public int Profile_ID { get; set; }
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public int Sequence { get; set; }
    public decimal TestMRP { get; set; }
    public string Reporting_Type { get; set; } = string.Empty;
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
}

public class LabInvestigationProfileFullDetailModel
{
    public LabInvestigationProfileHeaderModel Header { get; set; } = new();
    public List<LabInvestigationProfileDetailModel> Details { get; set; } = [];
}

public class LabInvestigationProfileDetailSaveModel
{
    public int? Detail_ID { get; set; }
    public int Test_ID { get; set; }
    public int Sequence { get; set; } = 1;
}

public class LabInvestigationProfileSaveRequestModel
{
    public int? Profile_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public string Profile_Name { get; set; } = string.Empty;
    public string Profile_Type { get; set; } = "Profile";
    public int? Test_ID { get; set; }
    public decimal MRP { get; set; }
    public decimal Discount_Pct { get; set; }
    public string? Age_Operator { get; set; }
    public int? Applicable_Age { get; set; }
    public string Applicable_Gender { get; set; } = "All";
    public int Profile_TAT_Hours { get; set; } = 24;
    public bool Profile_NABL_Accredited { get; set; }
    public int Report_Print_Sequence { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
    public List<LabInvestigationProfileDetailSaveModel> Details { get; set; } = [];
}

public class LabInvestigationProfileToggleStatusRequestModel
{
    public int Profile_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
