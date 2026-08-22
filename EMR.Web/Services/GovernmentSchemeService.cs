using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class GovernmentSchemeService(IDbConnectionFactory db) : IGovernmentSchemeService
{
    public async Task<IEnumerable<GovernmentSchemeListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? schemeType = null,
        bool? isActive = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@SchemeType", string.IsNullOrWhiteSpace(schemeType) ? null : schemeType.Trim());
        parameters.Add("@IsActive", isActive);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<GovernmentSchemeListItemViewModel>(
            "dbo.usp_Api_GovernmentScheme_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<GovernmentSchemeListItemViewModel?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<GovernmentSchemeListItemViewModel>(
            "dbo.usp_Api_GovernmentScheme_GetById",
            new { Scheme_ID = id },
            commandType: CommandType.StoredProcedure);
    }
}
