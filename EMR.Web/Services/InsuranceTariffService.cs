using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class InsuranceTariffService(IDbConnectionFactory db) : IInsuranceTariffService
{
    public async Task<IEnumerable<InsuranceTariffListItemViewModel>> GetListAsync(
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

        return await conn.QueryAsync<InsuranceTariffListItemViewModel>(
            "dbo.usp_InsuranceTariff_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<InsuranceTariffListItemViewModel?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<InsuranceTariffListItemViewModel>(
            "dbo.usp_InsuranceTariff_GetById",
            new { InsTariff_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<InsuranceMasterServiceItemViewModel>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@EntitlementType", string.IsNullOrWhiteSpace(entitlementType) ? null : entitlementType);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<InsuranceMasterServiceItemViewModel>(
            "dbo.usp_InsuranceTariff_GetMasterItems",
            parameters,
            commandType: CommandType.StoredProcedure);
    }
}
