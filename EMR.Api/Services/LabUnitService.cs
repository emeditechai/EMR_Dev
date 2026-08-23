using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabUnitService(IDbConnectionFactory db) : ILabUnitService
{
    public async Task<IEnumerable<LabUnitListItem>> GetListAsync(int? branchId, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabUnitListItem>(
            "usp_Api_LabUnitMaster_GetList",
            new { BranchId = branchId, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabUnitListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabUnitListItem>(
            "usp_Api_LabUnitMaster_GetById",
            new { Unit_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabUnitCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Unit_Name", req.Unit_Name);
        p.Add("@Unit_Symbol", req.Unit_Symbol);
        p.Add("@Conversion_Factor", req.Conversion_Factor);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@BranchId", req.BranchId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabUnitMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabUnitUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabUnitMaster_Update",
            new
            {
                Unit_ID = req.Unit_ID,
                Unit_Name = req.Unit_Name,
                Unit_Symbol = req.Unit_Symbol,
                Conversion_Factor = req.Conversion_Factor,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabUnitToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabUnitMaster_ToggleStatus",
            new
            {
                Unit_ID = req.Unit_ID,
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
            "usp_Api_LabUnitMaster_Delete",
            new { Unit_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
