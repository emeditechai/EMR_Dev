using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class GovernmentSchemeService(IDbConnectionFactory db) : IGovernmentSchemeService
{
    public async Task<IEnumerable<GovernmentSchemeListItemDto>> GetListAsync(
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

        return await conn.QueryAsync<GovernmentSchemeListItemDto>(
            "dbo.usp_Api_GovernmentScheme_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<GovernmentSchemeDetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<GovernmentSchemeDetailDto>(
            "dbo.usp_Api_GovernmentScheme_GetById",
            new { Scheme_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(GovernmentSchemeSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@SchemeCode", request.SchemeCode.Trim());
        parameters.Add("@SchemeName", request.SchemeName.Trim());
        parameters.Add("@SchemeType", request.SchemeType.Trim());
        parameters.Add("@AuthorityName", request.AuthorityName.Trim());
        parameters.Add("@RuleConfigJSON", string.IsNullOrWhiteSpace(request.RuleConfigJSON) ? null : request.RuleConfigJSON.Trim());
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewScheme_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Api_GovernmentScheme_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewScheme_ID");
    }

    public async Task<bool> UpdateAsync(int id, GovernmentSchemeSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Scheme_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@SchemeCode", request.SchemeCode.Trim());
        parameters.Add("@SchemeName", request.SchemeName.Trim());
        parameters.Add("@SchemeType", request.SchemeType.Trim());
        parameters.Add("@AuthorityName", request.AuthorityName.Trim());
        parameters.Add("@RuleConfigJSON", string.IsNullOrWhiteSpace(request.RuleConfigJSON) ? null : request.RuleConfigJSON.Trim());
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Api_GovernmentScheme_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Api_GovernmentScheme_ToggleStatus",
            new { Scheme_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Api_GovernmentScheme_Delete",
            new { Scheme_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }
}
