using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabParameterOptionService(IDbConnectionFactory db) : ILabParameterOptionService
{
    public async Task<IEnumerable<LabParameterOptionListItem>> GetListAsync(bool? status, string? search, int? companyId, int? test_ID)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabParameterOptionListItem>(
            "usp_Api_LabParameterOptionMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId, Test_ID = test_ID },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabParameterOptionListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabParameterOptionListItem>(
            "usp_Api_LabParameterOptionMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabParameterOptionCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Option_Text", req.Option_Text);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@Is_Abnormal", req.Is_Abnormal);
        p.Add("@Is_Default", req.Is_Default);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabParameterOptionMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabParameterOptionUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Option_ID);
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Option_Text", req.Option_Text);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@Is_Abnormal", req.Is_Abnormal);
        p.Add("@Is_Default", req.Is_Default);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabParameterOptionMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabParameterOptionToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabParameterOptionMaster_ToggleStatus",
            new { Id = req.Option_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabParameterOptionMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabParameterOptionLookupItem>> LookupTestsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabParameterOptionLookupItem>("usp_Api_LabParameterOptionMaster_LookupTests", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }
}
