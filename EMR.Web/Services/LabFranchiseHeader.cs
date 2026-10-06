using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Franchise Master "Report Header Required" (LabFranchiseMaster.IsReportHeaderRequired, script 2217) for a LAB bill:
/// a B2B bill of a franchise whose flag is No prints - and e-mails - its LAB bill and LAB reports without the hospital
/// header and footer (the space stays blank for the franchise's own letterhead). B2C bills and B2B bills of a company
/// are not affected.
/// </summary>
public static class LabFranchiseHeader
{
    /// <summary>The franchise's flag for a franchise B2B bill; null when the bill is B2C or billed to a company, so the
    /// existing header rules apply unchanged.</summary>
    public static async Task<bool?> ForOrderAsync(ApplicationDbContext db, int labOrderId)
    {
        if (labOrderId <= 0) return null;
        return await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<bool?>(@"
SELECT f.IsReportHeaderRequired
FROM dbo.LabOrder o
JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID
WHERE o.LabOrderId = @Id AND o.IsB2B = 1 AND o.AgentType = 'F'", new { Id = labOrderId });
    }
}
