using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Company > Remove data / Delete company: runs usp_Company_Purge (SQLScripts/2337) in one transaction.</summary>
public interface ICompanyPurgeService
{
    Task<List<CompanyPurgeResultRow>> PurgeAsync(CompanyPurgeRequest request);
}

public class CompanyPurgeService(IDbConnectionFactory db) : ICompanyPurgeService
{
    public async Task<List<CompanyPurgeResultRow>> PurgeAsync(CompanyPurgeRequest r)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<CompanyPurgeResultRow>("dbo.usp_Company_Purge",
            new { CompanyId = r.Level == "BRANCH" ? (int?)null : r.CompanyId, r.Level, r.Preview, r.UserId, r.BranchId },
            commandType: CommandType.StoredProcedure, commandTimeout: 1800);
        return rows.ToList();
    }
}
