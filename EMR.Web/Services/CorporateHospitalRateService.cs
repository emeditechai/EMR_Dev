using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class CorporateHospitalRateService(IDbConnectionFactory db) : ICorporateHospitalRateService
{
    public async Task<IEnumerable<CorporateHospitalRateListItemViewModel>> GetListAsync(
        int? corporateId = null,
        int? branchId = null,
        string? rateServiceType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Corporate_ID", corporateId);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@RateServiceType", string.IsNullOrWhiteSpace(rateServiceType) ? null : rateServiceType);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<CorporateHospitalRateListItemViewModel>(
            "dbo.usp_CorporateHospitalRate_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CorporateHospitalRateListItemViewModel?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<CorporateHospitalRateListItemViewModel>(
            "dbo.usp_CorporateHospitalRate_GetById",
            new { CorpRate_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MasterServiceItemViewModel>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@RateServiceType", string.IsNullOrWhiteSpace(rateServiceType) ? null : rateServiceType);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<MasterServiceItemViewModel>(
            "dbo.usp_CorporateHospitalRate_GetMasterItems",
            parameters,
            commandType: CommandType.StoredProcedure);
    }
}
