namespace EMR.Web.ApiClients.Models;

public class LabInvestigationModel
{
    public int Test_ID { get; set; }
    public int CompanyId { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
    public int Department_ID { get; set; }
    public string Department_Name { get; set; } = string.Empty;
    public string Department_Code { get; set; } = string.Empty;
    public int Category_ID { get; set; }
    public string Category_Name { get; set; } = string.Empty;
    public string Category_Code { get; set; } = string.Empty;
    public int? SubCategory_ID { get; set; }
    public string? SubCategory_Name { get; set; }
    public string? SubCategory_Code { get; set; }
    public int? Sample_Type_ID { get; set; }
    public string? Sample_Type_Name { get; set; }
    public int? Method_ID { get; set; }
    public string? Method_Name { get; set; }
    public int? Unit_ID { get; set; }
    public string? Unit_Name { get; set; }
    public string? Unit_Symbol { get; set; }
    public string Reporting_Type { get; set; } = "Numeric";
    public int? TAT_Hours { get; set; }
    public bool NABL_Accredited { get; set; }
    public string? NABL_Scope_No { get; set; }
    public bool Is_Outsourced { get; set; }
    public decimal MRP { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabInvestigationCreateRequestModel
{
    public int CompanyId { get; set; } = 1;
    public int Department_ID { get; set; }
    public int Category_ID { get; set; }
    public int? SubCategory_ID { get; set; }
    public int? Sample_Type_ID { get; set; }
    public int? Method_ID { get; set; }
    public int? Unit_ID { get; set; }
    public string Test_Name { get; set; } = string.Empty;
    public string Reporting_Type { get; set; } = "Numeric";
    public int TAT_Hours { get; set; } = 24;
    public bool NABL_Accredited { get; set; }
    public string? NABL_Scope_No { get; set; }
    public bool Is_Outsourced { get; set; }
    public decimal MRP { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabInvestigationUpdateRequestModel
{
    public int Test_ID { get; set; }
    public int Department_ID { get; set; }
    public int Category_ID { get; set; }
    public int? SubCategory_ID { get; set; }
    public int? Sample_Type_ID { get; set; }
    public int? Method_ID { get; set; }
    public int? Unit_ID { get; set; }
    public string Test_Name { get; set; } = string.Empty;
    public string Reporting_Type { get; set; } = "Numeric";
    public int TAT_Hours { get; set; } = 24;
    public bool NABL_Accredited { get; set; }
    public string? NABL_Scope_No { get; set; }
    public bool Is_Outsourced { get; set; }
    public decimal MRP { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabInvestigationToggleStatusRequestModel
{
    public int Test_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
