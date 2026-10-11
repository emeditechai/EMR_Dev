using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Misc Charges Master: every rule (type, amount, GST, duplicate name) is checked by the procedures (SQLScripts/2239).</summary>
public class LabMiscChargeService(IDbConnectionFactory connectionFactory) : ILabMiscChargeService
{
    public async Task<IEnumerable<LabMiscChargeModel>> GetListAsync(bool? status = null, string? chargeType = null, string? search = null, int? companyId = null)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryAsync<LabMiscChargeModel>(
            "dbo.usp_Api_LabMiscChargeMaster_GetList",
            new { Status = status, Charge_Type = chargeType, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabMiscChargeModel?> GetByIdAsync(int id)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryFirstOrDefaultAsync<LabMiscChargeModel>(
            "dbo.usp_Api_LabMiscChargeMaster_GetById",
            new { Misc_Charge_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabMiscChargeSaveRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = SaveParameters(request);
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await db.ExecuteAsync("dbo.usp_Api_LabMiscChargeMaster_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabMiscChargeSaveRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = SaveParameters(request);
        parameters.Add("@Misc_Charge_ID", request.Misc_Charge_ID);
        await db.ExecuteAsync("dbo.usp_Api_LabMiscChargeMaster_Update", parameters, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabMiscChargeToggleStatusRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Api_LabMiscChargeMaster_ToggleStatus",
            new { request.Misc_Charge_ID, request.Status, request.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Api_LabMiscChargeMaster_Delete",
            new { Misc_Charge_ID = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    private static DynamicParameters SaveParameters(LabMiscChargeSaveRequestModel r)
    {
        var p = new DynamicParameters();
        p.Add("@Charge_Name", r.Charge_Name);
        p.Add("@Charge_Type", r.Charge_Type);
        p.Add("@Amount", r.Amount);
        p.Add("@Is_Discountable", r.Is_Discountable);
        p.Add("@Is_GST_Required", r.Is_GST_Required);
        p.Add("@GST_Percentage", r.Is_GST_Required ? r.GST_Percentage : null);
        p.Add("@Description", r.Description);
        p.Add("@Display_Order", r.Display_Order);
        p.Add("@Status", r.Status);
        p.Add("@UserId", r.UserId);
        return p;
    }
}
