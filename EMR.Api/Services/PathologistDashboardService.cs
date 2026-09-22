using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface IPathologistDashboardService
{
    Task<PathologistAccessResult> GetAccessAsync(int userId, int branchId);
    Task<PathologistDashboardListResult> GetHeaderListAsync(int userId, int branchId, DateTime? fromDate, DateTime? toDate,
        string? dateBasis, string? search, int? departmentId, int? categoryId, string? statusFilter);
    Task<PathologistDetailResult> GetDetailAsync(int labOrderId, int userId, int branchId);
    /// <summary>Signs the next level; throws <see cref="InvalidOperationException"/> with the SQL rule message.</summary>
    Task<PathologistApproveResult> ApproveAsync(PathologistApproveRequest request);
}

public class PathologistDashboardService(IDbConnectionFactory connectionFactory) : IPathologistDashboardService
{
    public async Task<PathologistAccessResult> GetAccessAsync(int userId, int branchId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_PathologistDashboard_GetAccess",
            new { UserId = userId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        return new PathologistAccessResult
        {
            Profile = await multi.ReadFirstOrDefaultAsync<PathologistProfileDto>(),
            Departments = (await multi.ReadAsync<PathologistDepartmentDto>()).ToList(),
            Categories = (await multi.ReadAsync<PathologistCategoryDto>()).ToList()
        };
    }

    public async Task<PathologistDashboardListResult> GetHeaderListAsync(int userId, int branchId, DateTime? fromDate, DateTime? toDate,
        string? dateBasis, string? search, int? departmentId, int? categoryId, string? statusFilter)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_PathologistDashboard_GetHeaderList",
            new
            {
                UserId = userId,
                BranchId = branchId,
                FromDate = fromDate,
                ToDate = toDate,
                DateBasis = string.IsNullOrWhiteSpace(dateBasis) ? "BookingDate" : dateBasis,
                Search = search,
                DepartmentId = departmentId,
                CategoryId = categoryId,
                StatusFilter = string.IsNullOrWhiteSpace(statusFilter) ? "PENDING" : statusFilter
            },
            commandType: CommandType.StoredProcedure);

        return new PathologistDashboardListResult
        {
            Stats = await multi.ReadFirstOrDefaultAsync<PathologistDashboardStatsDto>() ?? new PathologistDashboardStatsDto(),
            Bills = (await multi.ReadAsync<PathologistBillDto>()).ToList()
        };
    }

    public async Task<PathologistDetailResult> GetDetailAsync(int labOrderId, int userId, int branchId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_PathologistDashboard_GetDetail",
            new { LabOrderId = labOrderId, UserId = userId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        return new PathologistDetailResult
        {
            Bill = await multi.ReadFirstOrDefaultAsync<PathologistBillDto>(),
            Tests = (await multi.ReadAsync<PathologistTestDto>()).ToList(),
            History = (await multi.ReadAsync<PathologistApprovalHistoryDto>()).ToList()
        };
    }

    public async Task<PathologistApproveResult> ApproveAsync(PathologistApproveRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        try
        {
            return await db.QueryFirstOrDefaultAsync<PathologistApproveResult>(
                "dbo.usp_Api_PathologistDashboard_Approve",
                new
                {
                    request.LabOrderId,
                    SamplecollectionIds = string.Join(",", request.SamplecollectionIds.Distinct()),
                    request.UserId,
                    request.BranchId,
                    request.Remarks
                },
                commandType: CommandType.StoredProcedure) ?? new PathologistApproveResult();
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            throw new InvalidOperationException(ex.Message);
        }
    }
}
