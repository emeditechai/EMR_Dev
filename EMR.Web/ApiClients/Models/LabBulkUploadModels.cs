namespace EMR.Web.ApiClients.Models;

public class LabBulkUploadResultModel
{
    public string Module { get; set; } = string.Empty;
    public string ModuleTitle { get; set; } = string.Empty;
    public bool DryRun { get; set; }
    public int TotalRows { get; set; }
    public int Inserted { get; set; }
    public int Updated { get; set; }
    public int Unchanged { get; set; }
    public int Failed { get; set; }
    public string? FileError { get; set; }
    public List<LabBulkUploadRowErrorModel> Errors { get; set; } = [];
    public List<LabBulkUploadViolationSummaryModel> ViolationSummary { get; set; } = [];
}

public class LabBulkUploadRowErrorModel
{
    public int RowNo { get; set; }
    public string RecordKey { get; set; } = string.Empty;
    public string Field { get; set; } = string.Empty;
    public string Rule { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
}

public class LabBulkUploadViolationSummaryModel
{
    public string Rule { get; set; } = string.Empty;
    public int Occurrences { get; set; }
    public int RowsAffected { get; set; }
}
