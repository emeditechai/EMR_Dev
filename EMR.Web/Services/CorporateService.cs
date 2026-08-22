using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class CorporateService(IDbConnectionFactory db) : ICorporateService
{
    public async Task<IEnumerable<CorporateListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CorporateType", string.IsNullOrWhiteSpace(type) ? null : type);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<CorporateListItemViewModel>(
            "dbo.usp_Api_Corporate_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CorporateMaster?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<CorporateMaster>(
            "dbo.usp_Corporate_GetById",
            new { Corporate_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeId = null, int? branchId = null)
    {
        using var conn = db.CreateConnection();
        const string sql = @"
            SELECT COUNT(1) FROM dbo.CorporateMaster 
            WHERE Corporate_Name = @Name
              AND (@BranchId IS NULL OR Branch_ID = @BranchId)
              AND (@ExcludeId IS NULL OR Corporate_ID <> @ExcludeId)";
        var count = await conn.ExecuteScalarAsync<int>(sql, new { Name = name.Trim(), BranchId = branchId, ExcludeId = excludeId });
        return count > 0;
    }
}
