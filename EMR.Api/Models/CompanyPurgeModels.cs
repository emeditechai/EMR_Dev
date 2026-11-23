namespace EMR.Api.Models;

/// <summary>Company > Remove data / Delete company (SQLScripts/2337, super admin only).</summary>
public class CompanyPurgeRequest
{
    public int CompanyId { get; set; }
    /// <summary>TRANSACTIONS, ALL, DELETE, or BRANCH (with BranchId - SQLScripts/2338).</summary>
    public string Level { get; set; } = "TRANSACTIONS";
    /// <summary>True: run and roll back, returning what would be removed.</summary>
    public bool Preview { get; set; } = true;
    public int? UserId { get; set; }
    /// <summary>BRANCH: the branch to remove.</summary>
    public int? BranchId { get; set; }
}

/// <summary>Rows removed (or that would be) from one table.</summary>
public class CompanyPurgeResultRow
{
    public string TableName { get; set; } = "";
    public int Rows { get; set; }
}
