using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DiscountTypeService(IDbConnectionFactory db) : IDiscountTypeService
{
    public async Task<IEnumerable<DiscountTypeListItem>> GetListAsync(int? branchId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<DiscountTypeListItem>(
            "dbo.usp_Api_DiscountType_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DiscountTypeDetail?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<DiscountTypeDetail>(
            "dbo.usp_DiscountType_GetById",
            new { DiscountTypeId = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(CreateDiscountTypeRequest request, int userId)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@DiscountTypeName", request.DiscountTypeName);
        parameters.Add("@DiscountFlag", request.DiscountFlag);
        parameters.Add("@PercentageFrom", request.PercentageFrom);
        parameters.Add("@PercentageTo", request.PercentageTo);
        parameters.Add("@DiscountAmount", request.DiscountAmount);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@CreatedBy", userId);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync(
            "dbo.usp_DiscountType_Create",
            parameters,
            commandType: CommandType.StoredProcedure);

        return parameters.Get<int>("@NewId");
    }

    public async Task UpdateAsync(UpdateDiscountTypeRequest request, int userId)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@DiscountTypeId", request.DiscountTypeId);
        parameters.Add("@DiscountTypeName", request.DiscountTypeName);
        parameters.Add("@DiscountFlag", request.DiscountFlag);
        parameters.Add("@PercentageFrom", request.PercentageFrom);
        parameters.Add("@PercentageTo", request.PercentageTo);
        parameters.Add("@DiscountAmount", request.DiscountAmount);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@ModifiedBy", userId);

        await conn.ExecuteAsync(
            "dbo.usp_DiscountType_Update",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id)
    {
        using var conn = db.CreateConnection();
        await conn.ExecuteAsync(
            "dbo.usp_DiscountType_Delete",
            new { DiscountTypeId = id },
            commandType: CommandType.StoredProcedure);
    }
}
