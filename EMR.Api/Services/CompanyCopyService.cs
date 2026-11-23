using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Company > Copy master data: runs usp_Company_CopyLabMasters (SQLScripts/2328) in one transaction.</summary>
public interface ICompanyCopyService
{
    Task<List<CompanyCopyResultRow>> CopyLabMastersAsync(CompanyCopyRequest request);
}

public class CompanyCopyService(IDbConnectionFactory db) : ICompanyCopyService
{
    public async Task<List<CompanyCopyResultRow>> CopyLabMastersAsync(CompanyCopyRequest r)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<CompanyCopyResultRow>("dbo.usp_Company_CopyLabMasters",
            new
            {
                r.SourceCompanyId, r.TargetCompanyId, Entities = string.Join(',', r.Entities ?? []),
                r.Preview, r.UserId
            },
            commandType: CommandType.StoredProcedure, commandTimeout: 600);
        return rows.ToList();
    }
}
