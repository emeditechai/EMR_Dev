using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabReportDispatchService(IDbConnectionFactory connectionFactory) : ILabReportDispatchService
{
    public async Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis,
        string? search, string? dispatchStatus, string? clientType, int? createdBy = null)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_LabReportDispatch_GetDashboard",
            new
            {
                BranchId = branchId,
                FromDate = fromDate,
                ToDate = toDate,
                DateBasis = string.IsNullOrWhiteSpace(dateBasis) ? "BillingDate" : dateBasis,
                Search = search,
                DispatchStatus = string.IsNullOrWhiteSpace(dispatchStatus) ? "ALL" : dispatchStatus,
                ClientType = string.IsNullOrWhiteSpace(clientType) ? "ALL" : clientType,
                CreatedBy = createdBy is > 0 ? createdBy : null   // script 2259
            },
            commandType: CommandType.StoredProcedure);

        return new LabReportDispatchResult
        {
            Stats = await multi.ReadFirstOrDefaultAsync<LabReportDispatchStatsDto>() ?? new LabReportDispatchStatsDto(),
            Rows = (await multi.ReadAsync<LabReportDispatchRowDto>()).ToList()
        };
    }

    public async Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryAsync<LabReportDispatchTestDto>(
            "dbo.usp_LabReportDispatch_GetBillTests",
            new { LabOrderId = labOrderId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<List<LabDuePrintStateDto>> GetDuePrintStatesAsync(IEnumerable<int> labOrderIds)
    {
        var ids = string.Join(",", labOrderIds.Where(i => i > 0).Distinct());
        if (ids.Length == 0) return [];
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<LabDuePrintStateDto>(
            "dbo.usp_LabDuePrint_GetStates", new { LabOrderIds = ids }, commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<LabDuePrintSubmitResult> SubmitDuePrintAsync(LabDuePrintSubmitRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_LabDuePrint_Submit",
            new { request.LabOrderId, request.UserId, Reason = string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim() },
            commandType: CommandType.StoredProcedure);
        var result = await multi.ReadFirstAsync<LabDuePrintSubmitResult>();
        result.ApproverIds = (await multi.ReadAsync<int>()).ToList();
        return result;
    }
}
