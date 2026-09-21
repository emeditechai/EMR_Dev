using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabApprovalFlowService(IDbConnectionFactory connectionFactory) : ILabApprovalFlowService
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public async Task<IEnumerable<LabApprovalFlowModel>> GetListAsync(int? companyId, int? branchScope, int? departmentId, int? categoryId, bool? status, string? search)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryAsync<LabApprovalFlowModel>(
            "dbo.usp_Api_LabApprovalFlow_GetList",
            new { CompanyId = companyId, BranchScope = branchScope, DepartmentId = departmentId, CategoryId = categoryId, Status = status, Search = search },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabApprovalFlowDetailModel?> GetByIdAsync(int id)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_LabApprovalFlow_GetById",
            new { Flow_ID = id },
            commandType: CommandType.StoredProcedure);

        var flow = await multi.ReadFirstOrDefaultAsync<LabApprovalFlowModel>();
        if (flow == null) return null;

        return new LabApprovalFlowDetailModel
        {
            Flow = flow,
            Levels = (await multi.ReadAsync<LabApprovalFlowLevelModel>()).ToList(),
            Approvers = (await multi.ReadAsync<LabApprovalFlowApproverModel>()).ToList()
        };
    }

    public async Task<int> CreateAsync(LabApprovalFlowCreateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Flow_Name", request.Flow_Name);
        p.Add("@Required_Levels", request.Required_Levels);
        p.Add("@Branch_ID", request.Branch_ID);
        p.Add("@Department_ID", request.Department_ID);
        p.Add("@Category_IDs", ToCsv(request.Category_IDs));
        p.Add("@Allow_Same_Approver", request.Allow_Same_Approver);
        p.Add("@LevelsJson", JsonSerializer.Serialize(request.Levels, Json));
        p.Add("@CompanyId", request.CompanyId);
        p.Add("@UserId", request.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await db.ExecuteAsync("dbo.usp_Api_LabApprovalFlow_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabApprovalFlowUpdateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Flow_ID", request.Flow_ID);
        p.Add("@Flow_Name", request.Flow_Name);
        p.Add("@Required_Levels", request.Required_Levels);
        p.Add("@Branch_ID", request.Branch_ID);
        p.Add("@Department_ID", request.Department_ID);
        p.Add("@Category_IDs", ToCsv(request.Category_IDs));
        p.Add("@Allow_Same_Approver", request.Allow_Same_Approver);
        p.Add("@Status", request.Status);
        p.Add("@LevelsJson", JsonSerializer.Serialize(request.Levels, Json));
        p.Add("@UserId", request.UserId);

        await db.ExecuteAsync("dbo.usp_Api_LabApprovalFlow_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabApprovalFlowToggleStatusRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_Api_LabApprovalFlow_ToggleStatus",
            new { request.Flow_ID, request.Status, request.UserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_Api_LabApprovalFlow_Delete",
            new { Flow_ID = id, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>"3,7,11" (distinct, ascending) or null when nothing is chosen - the format stored in the table.</summary>
    private static string? ToCsv(IEnumerable<int>? ids)
    {
        var list = (ids ?? Enumerable.Empty<int>()).Where(i => i > 0).Distinct().OrderBy(i => i).ToList();
        return list.Count == 0 ? null : string.Join(",", list);
    }

    public async Task<IEnumerable<LabApprovalEligibleApproverModel>> GetEligibleApproversAsync(int companyId, int? branchId, int? departmentId, string? categoryIds, bool includeIneligible = false)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryAsync<LabApprovalEligibleApproverModel>(
            "dbo.usp_Api_LabApprovalFlow_GetEligibleApprovers",
            new { CompanyId = companyId, BranchId = branchId, DepartmentId = departmentId, CategoryIds = categoryIds, IncludeIneligible = includeIneligible },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabApprovalFlowResolvedModel> ResolveAsync(int companyId, int? branchId, int? departmentId, int? categoryId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_LabApprovalFlow_Resolve",
            new { CompanyId = companyId, BranchId = branchId, DepartmentId = departmentId, CategoryId = categoryId },
            commandType: CommandType.StoredProcedure);

        var flow = await multi.ReadFirstOrDefaultAsync<LabApprovalFlowModel>();
        var levels = (await multi.ReadAsync<LabApprovalFlowLevelModel>()).ToList();
        var approvers = (await multi.ReadAsync<LabApprovalFlowApproverModel>()).ToList();

        if (flow == null) return new LabApprovalFlowResolvedModel { HasFlow = false };

        return new LabApprovalFlowResolvedModel
        {
            HasFlow = true,
            Detail = new LabApprovalFlowDetailModel { Flow = flow, Levels = levels, Approvers = approvers }
        };
    }
}
