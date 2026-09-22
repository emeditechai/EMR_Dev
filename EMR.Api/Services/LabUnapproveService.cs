using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface ILabUnapproveService
{
    Task<LabUnapproveListResult> GetHeaderListAsync(int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis, string? search, string? approvalType);
    Task<LabUnapproveDetailResult> GetDetailAsync(int labOrderId);
    /// <summary>Returns the number of tests un-approved; throws <see cref="InvalidOperationException"/> with the SQL validation message.</summary>
    Task<int> UnapproveAsync(LabUnapproveRequest request);
}

public class LabUnapproveService(IDbConnectionFactory connectionFactory) : ILabUnapproveService
{
    public async Task<LabUnapproveListResult> GetHeaderListAsync(int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis, string? search, string? approvalType)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_LabUnapprove_GetHeaderList",
            new
            {
                BranchId = branchId,
                FromDate = fromDate,
                ToDate = toDate,
                DateBasis = string.IsNullOrWhiteSpace(dateBasis) ? "ApprovedDate" : dateBasis,
                Search = search,
                ApprovalType = string.IsNullOrWhiteSpace(approvalType) ? "ALL" : approvalType
            },
            commandType: CommandType.StoredProcedure);

        return new LabUnapproveListResult
        {
            Stats = await multi.ReadFirstOrDefaultAsync<LabUnapproveStatsDto>() ?? new LabUnapproveStatsDto(),
            Headers = (await multi.ReadAsync<LabUnapproveHeaderDto>()).ToList()
        };
    }

    public async Task<LabUnapproveDetailResult> GetDetailAsync(int labOrderId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_LabUnapprove_GetDetail",
            new { LabOrderId = labOrderId },
            commandType: CommandType.StoredProcedure);

        return new LabUnapproveDetailResult
        {
            Bill = await multi.ReadFirstOrDefaultAsync<LabUnapproveBillDto>(),
            Tests = (await multi.ReadAsync<LabUnapproveTestDto>()).ToList()
        };
    }

    public async Task<int> UnapproveAsync(LabUnapproveRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        try
        {
            return await db.QueryFirstOrDefaultAsync<int>(
                "dbo.usp_LabUnapprove_Execute",
                new
                {
                    request.LabOrderId,
                    SamplecollectionIds = string.Join(",", request.SamplecollectionIds.Distinct()),
                    request.Reason,
                    request.UserId,
                    Action = string.IsNullOrWhiteSpace(request.Action) ? "RETEST" : request.Action.Trim().ToUpperInvariant()
                },
                commandType: CommandType.StoredProcedure);
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            throw new InvalidOperationException(ex.Message);
        }
    }
}
