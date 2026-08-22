using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class HospitalPackageService(IDbConnectionFactory dbFactory) : IHospitalPackageService
{
    public async Task<IEnumerable<HospitalPackageListItemDto>> GetListAsync(
        int? branchId, string? packageType, bool? status, string? search, int? companyId)
    {
        using var conn = dbFactory.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@BranchId", branchId);
        param.Add("@PackageType", string.IsNullOrWhiteSpace(packageType) ? null : packageType);
        param.Add("@Status", status);
        param.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search);
        param.Add("@CompanyId", companyId);

        return await conn.QueryAsync<HospitalPackageListItemDto>(
            "dbo.usp_HospitalPackage_GetList",
            param,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<HospitalPackageHeaderDto?> GetByIdAsync(int id)
    {
        using var conn = dbFactory.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@HospitalPackage_ID", id);

        using var multi = await conn.QueryMultipleAsync(
            "dbo.usp_HospitalPackage_GetById",
            param,
            commandType: CommandType.StoredProcedure);

        var header = await multi.ReadFirstOrDefaultAsync<HospitalPackageHeaderDto>();
        if (header is null) return null;

        var details = (await multi.ReadAsync<HospitalPackageDetailDto>()).ToList();
        header.Details = details;

        return header;
    }

    public async Task<int> CreateAsync(HospitalPackageSaveRequest request)
    {
        using var conn = dbFactory.CreateConnection();
        var jsonOptions = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        var detailsJson = JsonSerializer.Serialize(request.Details ?? [], jsonOptions);

        var param = new DynamicParameters();
        param.Add("@CompanyId", request.CompanyId);
        param.Add("@Branch_ID", request.Branch_ID);
        param.Add("@Package_Code", request.Package_Code.Trim());
        param.Add("@Package_Name", request.Package_Name.Trim());
        param.Add("@Package_Type", request.Package_Type.Trim());
        param.Add("@ValidFrom", request.ValidFrom);
        param.Add("@ValidTo", request.ValidTo);
        param.Add("@TotalPackageAmount", request.TotalPackageAmount);
        param.Add("@Description", string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim());
        param.Add("@Status", request.Status);
        param.Add("@CreatedBy", request.UserId);
        param.Add("@DetailsJson", detailsJson);
        param.Add("@NewHospitalPackage_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_HospitalPackage_Create", param, commandType: CommandType.StoredProcedure);
        return param.Get<int>("@NewHospitalPackage_ID");
    }

    public async Task<bool> UpdateAsync(int id, HospitalPackageSaveRequest request)
    {
        using var conn = dbFactory.CreateConnection();
        var jsonOptions = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        var detailsJson = JsonSerializer.Serialize(request.Details ?? [], jsonOptions);

        var param = new DynamicParameters();
        param.Add("@HospitalPackage_ID", id);
        param.Add("@CompanyId", request.CompanyId);
        param.Add("@Branch_ID", request.Branch_ID);
        param.Add("@Package_Code", request.Package_Code.Trim());
        param.Add("@Package_Name", request.Package_Name.Trim());
        param.Add("@Package_Type", request.Package_Type.Trim());
        param.Add("@ValidFrom", request.ValidFrom);
        param.Add("@ValidTo", request.ValidTo);
        param.Add("@TotalPackageAmount", request.TotalPackageAmount);
        param.Add("@Description", string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim());
        param.Add("@Status", request.Status);
        param.Add("@ModifiedBy", request.UserId);
        param.Add("@DetailsJson", detailsJson);

        var rows = await conn.ExecuteAsync("dbo.usp_HospitalPackage_Update", param, commandType: CommandType.StoredProcedure);
        return true;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId)
    {
        using var conn = dbFactory.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@HospitalPackage_ID", id);
        param.Add("@ModifiedBy", userId);

        await conn.ExecuteAsync("dbo.usp_HospitalPackage_ToggleStatus", param, commandType: CommandType.StoredProcedure);
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        using var conn = dbFactory.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@HospitalPackage_ID", id);
        param.Add("@DeletedBy", userId);

        await conn.ExecuteAsync("dbo.usp_HospitalPackage_Delete", param, commandType: CommandType.StoredProcedure);
        return true;
    }

    public async Task<IEnumerable<MasterLookupItemDto>> GetMasterLookupsAsync(int? branchId, int? companyId)
    {
        using var conn = dbFactory.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@BranchId", branchId);
        param.Add("@CompanyId", companyId);

        return await conn.QueryAsync<MasterLookupItemDto>(
            "dbo.usp_HospitalPackage_GetMasterLookups",
            param,
            commandType: CommandType.StoredProcedure);
    }
}
