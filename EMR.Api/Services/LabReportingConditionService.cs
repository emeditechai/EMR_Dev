using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabReportingConditionService(IDbConnectionFactory connectionFactory) : ILabReportingConditionService
{
    public async Task<IEnumerable<LabReportingConditionModel>> GetListAsync(bool? status = null, int? branchScope = null, string? search = null, int? companyId = null)
    {
        using var db = connectionFactory.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Status", status);
        p.Add("@BranchScope", branchScope);
        p.Add("@Search", search);
        p.Add("@CompanyId", companyId);

        return await db.QueryAsync<LabReportingConditionModel>(
            "dbo.usp_Api_LabReportingConditionMaster_GetList", p, commandType: CommandType.StoredProcedure);
    }

    public async Task<LabReportingConditionModel?> GetByIdAsync(int id)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryFirstOrDefaultAsync<LabReportingConditionModel>(
            "dbo.usp_Api_LabReportingConditionMaster_GetById",
            new { Condition_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabReportingConditionCreateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Condition_Text", request.Condition_Text);
        p.Add("@Branch_ID", request.Branch_ID);
        p.Add("@Display_Order", request.Display_Order);
        p.Add("@CompanyId", request.CompanyId);
        p.Add("@UserId", request.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await db.ExecuteAsync("dbo.usp_Api_LabReportingConditionMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabReportingConditionUpdateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Condition_ID", request.Condition_ID);
        p.Add("@Condition_Text", request.Condition_Text);
        p.Add("@Branch_ID", request.Branch_ID);
        p.Add("@Display_Order", request.Display_Order);
        p.Add("@Status", request.Status);
        p.Add("@UserId", request.UserId);

        await db.ExecuteAsync("dbo.usp_Api_LabReportingConditionMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabReportingConditionToggleStatusRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_Api_LabReportingConditionMaster_ToggleStatus",
            new { request.Condition_ID, request.Status, request.UserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_Api_LabReportingConditionMaster_Delete",
            new { Condition_ID = id, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabReportConditionsForReportModel> GetForReportAsync(int companyId, int? branchId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_LabReportingConditionMaster_GetForReport",
            new { CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        var texts = (await multi.ReadAsync<string>()).ToList();
        var hasConfig = await multi.ReadFirstOrDefaultAsync<bool>();

        return new LabReportConditionsForReportModel { HasConfiguration = hasConfig, Conditions = texts };
    }
}
