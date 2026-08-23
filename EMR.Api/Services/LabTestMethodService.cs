using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabTestMethodService(IDbConnectionFactory db) : ILabTestMethodService
{
    public async Task<IEnumerable<LabTestMethodListItem>> GetListAsync(int? branchId, int? departmentId, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabTestMethodListItem>(
            "usp_Api_LabTestMethodMaster_GetList",
            new { BranchId = branchId, DepartmentId = departmentId, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabTestMethodListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabTestMethodListItem>(
            "usp_Api_LabTestMethodMaster_GetById",
            new { Method_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabTestMethodCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Department_ID", req.Department_ID);
        p.Add("@Method_Name", req.Method_Name);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@BranchId", req.BranchId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabTestMethodMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabTestMethodUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestMethodMaster_Update",
            new
            {
                Method_ID = req.Method_ID,
                Department_ID = req.Department_ID,
                Method_Name = req.Method_Name,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabTestMethodToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestMethodMaster_ToggleStatus",
            new
            {
                Method_ID = req.Method_ID,
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
            "usp_Api_LabTestMethodMaster_Delete",
            new { Method_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
