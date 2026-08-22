using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class InsuranceTPAService(IDbConnectionFactory db) : IInsuranceTPAService
{
    public async Task<IEnumerable<InsuranceTPAListItemDto>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@Type", string.IsNullOrWhiteSpace(type) ? null : type);
        parameters.Add("@NetworkCategory", string.IsNullOrWhiteSpace(networkCategory) ? null : networkCategory);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<InsuranceTPAListItemDto>(
            "dbo.usp_Api_InsuranceTPA_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<InsuranceTPADetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<InsuranceTPADetailDto>(
            "dbo.usp_InsuranceTPA_GetById",
            new { InsuranceTPA_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(InsuranceTPASaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Type", request.Type.Trim());
        parameters.Add("@Name", request.Name.Trim());
        parameters.Add("@Code", request.Code.Trim().ToUpperInvariant());
        parameters.Add("@SchemeName", string.IsNullOrWhiteSpace(request.SchemeName) ? null : request.SchemeName.Trim());
        parameters.Add("@PolicyPrefix", string.IsNullOrWhiteSpace(request.PolicyPrefix) ? null : request.PolicyPrefix.Trim().ToUpperInvariant());
        parameters.Add("@NetworkCategory", request.NetworkCategory.Trim());
        parameters.Add("@AuthorizationRequired", request.AuthorizationRequired);
        parameters.Add("@ContactPerson", string.IsNullOrWhiteSpace(request.ContactPerson) ? null : request.ContactPerson.Trim());
        parameters.Add("@ContactNumber", string.IsNullOrWhiteSpace(request.ContactNumber) ? null : request.ContactNumber.Trim());
        parameters.Add("@Email", string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewInsuranceTPA_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_InsuranceTPA_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewInsuranceTPA_ID");
    }

    public async Task<bool> UpdateAsync(int id, InsuranceTPASaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@InsuranceTPA_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Type", request.Type.Trim());
        parameters.Add("@Name", request.Name.Trim());
        parameters.Add("@Code", request.Code.Trim().ToUpperInvariant());
        parameters.Add("@SchemeName", string.IsNullOrWhiteSpace(request.SchemeName) ? null : request.SchemeName.Trim());
        parameters.Add("@PolicyPrefix", string.IsNullOrWhiteSpace(request.PolicyPrefix) ? null : request.PolicyPrefix.Trim().ToUpperInvariant());
        parameters.Add("@NetworkCategory", request.NetworkCategory.Trim());
        parameters.Add("@AuthorizationRequired", request.AuthorizationRequired);
        parameters.Add("@ContactPerson", string.IsNullOrWhiteSpace(request.ContactPerson) ? null : request.ContactPerson.Trim());
        parameters.Add("@ContactNumber", string.IsNullOrWhiteSpace(request.ContactNumber) ? null : request.ContactNumber.Trim());
        parameters.Add("@Email", string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_InsuranceTPA_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_InsuranceTPA_ToggleStatus",
            new { InsuranceTPA_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_InsuranceTPA_Delete",
            new { InsuranceTPA_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }
}
