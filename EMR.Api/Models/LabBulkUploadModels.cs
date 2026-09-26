namespace EMR.Api.Models;

/// <summary>Outcome of one bulk upload (or dry run) for a lab master.</summary>
public class LabBulkUploadResult
{
    public string Module { get; set; } = string.Empty;
    public string ModuleTitle { get; set; } = string.Empty;
    public bool DryRun { get; set; }
    public int TotalRows { get; set; }
    public int Inserted { get; set; }
    public int Updated { get; set; }
    public int Unchanged { get; set; }
    public int Failed { get; set; }

    /// <summary>Set when the file itself could not be read (wrong sheet, missing headers, ...).</summary>
    public string? FileError { get; set; }

    public List<LabBulkUploadRowError> Errors { get; set; } = [];
    public List<LabBulkUploadViolationSummary> ViolationSummary { get; set; } = [];
}

/// <summary>One validation / save failure on one row. A row may carry several.</summary>
public class LabBulkUploadRowError
{
    public int RowNo { get; set; }
    public string RecordKey { get; set; } = string.Empty;
    public string Field { get; set; } = string.Empty;
    public string Rule { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
}

/// <summary>Failures grouped by the rule that was violated.</summary>
public class LabBulkUploadViolationSummary
{
    public string Rule { get; set; } = string.Empty;
    public int Occurrences { get; set; }
    public int RowsAffected { get; set; }
}

public static class LabBulkUploadRules
{
    public const string Required        = "Required field missing";
    public const string InvalidValue    = "Invalid value / format";
    public const string InvalidRef      = "Dependent master not found";
    public const string MismatchedRef   = "Dependent master mismatch";
    public const string DuplicateInFile = "Duplicate row in file";
    public const string AlreadyExists   = "Already exists in system";
    public const string NotFound        = "Code not found for update";
    public const string AccessDenied    = "Branch access denied";
    public const string SaveFailed      = "Save failed (database)";
}
