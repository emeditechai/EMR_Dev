using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class InsuranceTariffService(IDbConnectionFactory db) : IInsuranceTariffService
{
    public async Task<IEnumerable<InsuranceTariffListItemDto>> GetListAsync(
        int? insuranceTpaId = null,
        int? branchId = null,
        string? entitlementType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@InsuranceTPA_ID", insuranceTpaId);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@EntitlementType", string.IsNullOrWhiteSpace(entitlementType) ? null : entitlementType);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<InsuranceTariffListItemDto>(
            "dbo.usp_InsuranceTariff_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<InsuranceTariffDetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<InsuranceTariffDetailDto>(
            "dbo.usp_InsuranceTariff_GetById",
            new { InsTariff_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(InsuranceTariffSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@InsuranceTPA_ID", request.InsuranceTPA_ID);
        parameters.Add("@EntitlementType", request.EntitlementType.Trim());
        parameters.Add("@Reference_ID", request.Reference_ID);
        parameters.Add("@DeductionRuleType", request.DeductionRuleType.Trim());
        parameters.Add("@DeductionValue", request.DeductionValue);
        parameters.Add("@Rate", request.Rate);
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewInsTariff_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_InsuranceTariff_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewInsTariff_ID");
    }

    public async Task<bool> UpdateAsync(int id, InsuranceTariffSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@InsTariff_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@InsuranceTPA_ID", request.InsuranceTPA_ID);
        parameters.Add("@EntitlementType", request.EntitlementType.Trim());
        parameters.Add("@Reference_ID", request.Reference_ID);
        parameters.Add("@DeductionRuleType", request.DeductionRuleType.Trim());
        parameters.Add("@DeductionValue", request.DeductionValue);
        parameters.Add("@Rate", request.Rate);
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_InsuranceTariff_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_InsuranceTariff_ToggleStatus",
            new { InsTariff_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_InsuranceTariff_Delete",
            new { InsTariff_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<IEnumerable<InsuranceMasterServiceItemDto>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@EntitlementType", string.IsNullOrWhiteSpace(entitlementType) ? null : entitlementType);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<InsuranceMasterServiceItemDto>(
            "dbo.usp_InsuranceTariff_GetMasterItems",
            parameters,
            commandType: CommandType.StoredProcedure);
    }
}
