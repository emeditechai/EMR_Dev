namespace EMR.Web.ApiClients.Models;

public class AnalyzerListItem
{
    public int Analyzer_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string BranchCode { get; set; } = string.Empty;
    public int Department_ID { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public string DepartmentType { get; set; } = string.Empty;
    public string Analyzer_Name { get; set; } = string.Empty;
    public string Interface_Protocol { get; set; } = string.Empty;
    public bool Status { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? ModifiedBy { get; set; }
}

public class AnalyzerDetail : AnalyzerListItem
{
}

public class AnalyzerSaveRequest
{
    public int? Analyzer_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public int Department_ID { get; set; }
    public string Analyzer_Name { get; set; } = string.Empty;
    public string Interface_Protocol { get; set; } = string.Empty; // HL7 / ASTM / Manual Entry
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}
