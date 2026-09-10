using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabSampleRejectionService(IDbConnectionFactory db) : ILabSampleRejectionService
{
    public async Task<IEnumerable<LabSampleRejectionListItem>> GetListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabSampleRejectionListItem>(
            "usp_Api_LabSampleRejectionMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabSampleRejectionListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabSampleRejectionListItem>(
            "usp_Api_LabSampleRejectionMaster_GetById",
            new { Rejection_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabSampleRejectionCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Rejection_Reason", req.Rejection_Reason);
        p.Add("@Description", req.Description);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabSampleRejectionMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabSampleRejectionUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabSampleRejectionMaster_Update",
            new
            {
                Rejection_ID = req.Rejection_ID,
                Rejection_Reason = req.Rejection_Reason,
                Description = req.Description,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabSampleRejectionToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabSampleRejectionMaster_ToggleStatus",
            new
            {
                Rejection_ID = req.Rejection_ID,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabSampleRejectionMaster_Delete",
            new { Rejection_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
