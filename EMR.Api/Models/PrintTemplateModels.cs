namespace EMR.Api.Models;

/// <summary>Utility > Print Templates (SQLScripts/2324): bill / lab report header and footer templates.</summary>
public class PrintTemplateRow
{
    public int TemplateId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public int Version { get; set; }
    public bool IsPublished { get; set; }
    public bool HasUnpublishedChanges { get; set; }
    public DateTime ModifiedDate { get; set; }
    public string? ModifiedByName { get; set; }
    public DateTime? PublishedDate { get; set; }
    public string? Branches { get; set; }
}

public class PrintTemplateDetail
{
    public int TemplateId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public string DraftJson { get; set; } = "{}";
    public string? LayoutJson { get; set; }
    public int Version { get; set; }
    public bool IsPublished { get; set; }
    public DateTime ModifiedDate { get; set; }
    public DateTime? PublishedDate { get; set; }
    public List<PrintTemplateVersionRow> Versions { get; set; } = [];
}

public class PrintTemplateVersionRow
{
    public int VersionNo { get; set; }
    public DateTime PublishedDate { get; set; }
    public string? PublishedByName { get; set; }
}

public class PrintTemplateAssignmentRow
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public bool IsHOBranch { get; set; }
    public int? BillTemplateId { get; set; }
    public int? ReportTemplateId { get; set; }
}

public class PrintTemplateResolved
{
    public int TemplateId { get; set; }
    public int Version { get; set; }
    public string LayoutJson { get; set; } = "{}";
}

public class PrintTemplateSaveRequest
{
    public int CompanyId { get; set; }
    public int TemplateId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public string DraftJson { get; set; } = "{}";
    public int UserId { get; set; }
}

public class PrintTemplateActionRequest
{
    public int CompanyId { get; set; }
    public int TemplateId { get; set; }
    public int? VersionNo { get; set; }
    public int UserId { get; set; }
}

public class PrintTemplateAssignRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string Kind { get; set; } = "";
    public int? TemplateId { get; set; }
    public int UserId { get; set; }
}
