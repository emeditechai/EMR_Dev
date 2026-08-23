using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabTestSubCategoryService(IDbConnectionFactory db) : ILabTestSubCategoryService
{
    public async Task<IEnumerable<LabTestSubCategoryListItem>> GetListAsync(int? branchId, int? categoryId, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabTestSubCategoryListItem>(
            "usp_Api_LabTestSubCategoryMaster_GetList",
            new { BranchId = branchId, CategoryId = categoryId, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabTestSubCategoryListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabTestSubCategoryListItem>(
            "usp_Api_LabTestSubCategoryMaster_GetById",
            new { SubCategory_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabTestSubCategoryCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Category_ID", req.Category_ID);
        p.Add("@SubCategory_Name", req.SubCategory_Name);
        p.Add("@Display_Order", req.Display_Order);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@BranchId", req.BranchId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabTestSubCategoryMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabTestSubCategoryUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestSubCategoryMaster_Update",
            new
            {
                SubCategory_ID = req.SubCategory_ID,
                Category_ID = req.Category_ID,
                SubCategory_Name = req.SubCategory_Name,
                Display_Order = req.Display_Order,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabTestSubCategoryToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabTestSubCategoryMaster_ToggleStatus",
            new
            {
                SubCategory_ID = req.SubCategory_ID,
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
            "usp_Api_LabTestSubCategoryMaster_Delete",
            new { SubCategory_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
