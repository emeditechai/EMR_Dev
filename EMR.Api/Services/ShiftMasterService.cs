using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class ShiftMasterService(IDbConnectionFactory db) : IShiftMasterService
{
    public async Task<IEnumerable<ShiftMasterListItemDto>> GetListAsync(
        int? branchId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<ShiftMasterListItemDto>(
            "dbo.usp_Api_ShiftMaster_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ShiftMasterDetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<ShiftMasterDetailDto>(
            "dbo.usp_Api_ShiftMaster_GetById",
            new { ShiftMaster_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(ShiftMasterSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@ShiftCode", request.ShiftCode.Trim());
        parameters.Add("@ShiftName", request.ShiftName.Trim());
        parameters.Add("@StartTime", request.StartTime);
        parameters.Add("@EndTime", request.EndTime);
        parameters.Add("@GraceTimeMinutes", request.GraceTimeMinutes);
        parameters.Add("@BreakDurationMinutes", request.BreakDurationMinutes);
        parameters.Add("@IsNightShift", request.IsNightShift);
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewShiftMaster_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Api_ShiftMaster_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewShiftMaster_ID");
    }

    public async Task<bool> UpdateAsync(int id, ShiftMasterSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@ShiftMaster_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@ShiftCode", request.ShiftCode.Trim());
        parameters.Add("@ShiftName", request.ShiftName.Trim());
        parameters.Add("@StartTime", request.StartTime);
        parameters.Add("@EndTime", request.EndTime);
        parameters.Add("@GraceTimeMinutes", request.GraceTimeMinutes);
        parameters.Add("@BreakDurationMinutes", request.BreakDurationMinutes);
        parameters.Add("@IsNightShift", request.IsNightShift);
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Api_ShiftMaster_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Api_ShiftMaster_ToggleStatus",
            new { ShiftMaster_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Api_ShiftMaster_Delete",
            new { ShiftMaster_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }
}
