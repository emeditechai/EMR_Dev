namespace EMR.Api.Models;

/// <summary>Company > Copy master data (SQLScripts/2328): the target company pulls LAB masters from a source company.</summary>
public class CompanyCopyRequest
{
    public int SourceCompanyId { get; set; }
    public int TargetCompanyId { get; set; }
    /// <summary>CATEGORY, SUBCATEGORY, SAMPLETYPE, METHOD, INVESTIGATION, PROFILE, REFRANGE, DESCRIPTIVE, ORGANISM, ANTIBIOTIC, PANEL, SHIFT, EMRTEMPLATE, SMTP, VIDEO.</summary>
    public List<string> Entities { get; set; } = [];
    /// <summary>True: run and roll back, returning what would happen.</summary>
    public bool Preview { get; set; } = true;
    public int? UserId { get; set; }
}

/// <summary>One master in the result: rows in the source, already in the target (linked), copied, skipped.</summary>
public class CompanyCopyResultRow
{
    public string EntityKey { get; set; } = "";
    public string Entity { get; set; } = "";
    public int InSource { get; set; }
    public int Existing { get; set; }
    public int Copied { get; set; }
    public int Skipped { get; set; }
    /// <summary>Not ticked: came along as a parent or child of a ticked master.</summary>
    public bool Auto { get; set; }
}
