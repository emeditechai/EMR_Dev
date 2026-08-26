using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabInvestigationService(IDbConnectionFactory db) : ILabInvestigationService
{
    public async Task<IEnumerable<LabInvestigationListItem>> GetListAsync(int? departmentId, int? categoryId, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabInvestigationListItem>(
            "usp_Api_LabInvestigationMaster_GetList",
            new { DepartmentId = departmentId, CategoryId = categoryId, Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabInvestigationListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabInvestigationListItem>(
            "usp_Api_LabInvestigationMaster_GetById",
            new { Test_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabInvestigationCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@Department_ID", req.Department_ID);
        p.Add("@Category_ID", req.Category_ID);
        p.Add("@SubCategory_ID", req.SubCategory_ID);
        p.Add("@Sample_Type_ID", req.Sample_Type_ID);
        p.Add("@Method_ID", req.Method_ID);
        p.Add("@Unit_ID", req.Unit_ID);
        p.Add("@Test_Name", req.Test_Name);
        p.Add("@Reporting_Type", req.Reporting_Type);
        p.Add("@TAT_Hours", req.TAT_Hours);
        p.Add("@NABL_Accredited", req.NABL_Accredited);
        p.Add("@NABL_Scope_No", req.NABL_Scope_No);
        p.Add("@Is_Outsourced", req.Is_Outsourced);
        p.Add("@MRP", req.MRP);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);

        var result = await con.ExecuteScalarAsync<object>("usp_Api_LabInvestigationMaster_Create", p, commandType: CommandType.StoredProcedure);
        return Convert.ToInt32(result);
    }

    public async Task UpdateAsync(LabInvestigationUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Department_ID", req.Department_ID);
        p.Add("@Category_ID", req.Category_ID);
        p.Add("@SubCategory_ID", req.SubCategory_ID);
        p.Add("@Sample_Type_ID", req.Sample_Type_ID);
        p.Add("@Method_ID", req.Method_ID);
        p.Add("@Unit_ID", req.Unit_ID);
        p.Add("@Test_Name", req.Test_Name);
        p.Add("@Reporting_Type", req.Reporting_Type);
        p.Add("@TAT_Hours", req.TAT_Hours);
        p.Add("@NABL_Accredited", req.NABL_Accredited);
        p.Add("@NABL_Scope_No", req.NABL_Scope_No);
        p.Add("@Is_Outsourced", req.Is_Outsourced);
        p.Add("@MRP", req.MRP);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);

        await con.ExecuteAsync("usp_Api_LabInvestigationMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabInvestigationToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabInvestigationMaster_ToggleStatus",
            new { Test_ID = req.Test_ID, Status = req.Status, UserId = req.UserId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabInvestigationMaster_Delete",
            new { Test_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }
}
