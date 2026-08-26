using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabTestCategoryService(IDbConnectionFactory db) : ILabTestCategoryService
{
    public async Task<IEnumerable<LabTestCategoryListItem>> GetListAsync(int? departmentId, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabTestCategoryListItem>(
            "usp_Api_LabTestCategoryMaster_GetList",
            new { DepartmentId = departmentId, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabTestCategoryListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabTestCategoryListItem>(
            "usp_Api_LabTestCategoryMaster_GetById",
            new { Category_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabTestCategoryCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Department_ID", req.Department_ID);
        p.Add("@Category_Name", req.Category_Name);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabTestCategoryMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabTestCategoryUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestCategoryMaster_Update",
            new
            {
                Category_ID = req.Category_ID,
                Department_ID = req.Department_ID,
                Category_Name = req.Category_Name,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabTestCategoryToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestCategoryMaster_ToggleStatus",
            new
            {
                Category_ID = req.Category_ID,
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
            "usp_Api_LabTestCategoryMaster_Delete",
            new { Category_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
