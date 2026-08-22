using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class CorporateHospitalRateService(IDbConnectionFactory db) : ICorporateHospitalRateService
{
    public async Task<IEnumerable<CorporateHospitalRateListItemDto>> GetListAsync(
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

        return await conn.QueryAsync<CorporateHospitalRateListItemDto>(
            "dbo.usp_CorporateHospitalRate_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CorporateHospitalRateDetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<CorporateHospitalRateDetailDto>(
            "dbo.usp_CorporateHospitalRate_GetById",
            new { CorpRate_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(CorporateHospitalRateSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Corporate_ID", request.Corporate_ID);
        parameters.Add("@RateServiceType", request.RateServiceType.Trim());
        parameters.Add("@ReferenceMaster_ID", request.ReferenceMaster_ID);
        parameters.Add("@RateType", request.RateType.Trim());
        parameters.Add("@Rate", request.Rate);
        parameters.Add("@DiscountPercent", request.DiscountPercent);
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewCorpRate_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_CorporateHospitalRate_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewCorpRate_ID");
    }

    public async Task<bool> UpdateAsync(int id, CorporateHospitalRateSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CorpRate_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Corporate_ID", request.Corporate_ID);
        parameters.Add("@RateServiceType", request.RateServiceType.Trim());
        parameters.Add("@ReferenceMaster_ID", request.ReferenceMaster_ID);
        parameters.Add("@RateType", request.RateType.Trim());
        parameters.Add("@Rate", request.Rate);
        parameters.Add("@DiscountPercent", request.DiscountPercent);
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_CorporateHospitalRate_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_CorporateHospitalRate_ToggleStatus",
            new { CorpRate_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_CorporateHospitalRate_Delete",
            new { CorpRate_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<IEnumerable<MasterServiceItemDto>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@RateServiceType", string.IsNullOrWhiteSpace(rateServiceType) ? null : rateServiceType);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<MasterServiceItemDto>(
            "dbo.usp_CorporateHospitalRate_GetMasterItems",
            parameters,
            commandType: CommandType.StoredProcedure);
    }
}
