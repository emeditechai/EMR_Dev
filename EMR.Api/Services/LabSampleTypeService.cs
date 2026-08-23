using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabSampleTypeService(IDbConnectionFactory db) : ILabSampleTypeService
{
    public async Task<IEnumerable<LabSampleTypeListItem>> GetListAsync(int? branchId, string? containerType, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabSampleTypeListItem>(
            "usp_Api_LabSampleTypeMaster_GetList",
            new { BranchId = branchId, ContainerType = containerType, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabSampleTypeListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabSampleTypeListItem>(
            "usp_Api_LabSampleTypeMaster_GetById",
            new { Sample_Type_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabSampleTypeCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Sample_Name", req.Sample_Name);
        p.Add("@Container_Type", req.Container_Type.GetDisplayName());
        p.Add("@Volume_Value", req.Volume_Value);
        p.Add("@Unit_ID", req.Unit_ID);
        p.Add("@Volume_Unit", req.Volume_Unit);
        p.Add("@Storage_Temperature", req.Storage_Temperature);
        p.Add("@Rejection_Criteria", req.Rejection_Criteria);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@BranchId", req.BranchId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabSampleTypeMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabSampleTypeUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabSampleTypeMaster_Update",
            new
            {
                Sample_Type_ID = req.Sample_Type_ID,
                Sample_Name = req.Sample_Name,
                Container_Type = req.Container_Type.GetDisplayName(),
                Volume_Value = req.Volume_Value,
                Unit_ID = req.Unit_ID,
                Volume_Unit = req.Volume_Unit,
                Storage_Temperature = req.Storage_Temperature,
                Rejection_Criteria = req.Rejection_Criteria,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabSampleTypeToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabSampleTypeMaster_ToggleStatus",
            new
            {
                Sample_Type_ID = req.Sample_Type_ID,
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
            "usp_Api_LabSampleTypeMaster_Delete",
            new { Sample_Type_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
