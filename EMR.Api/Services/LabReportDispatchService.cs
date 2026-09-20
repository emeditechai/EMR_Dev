using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabReportDispatchService(IDbConnectionFactory connectionFactory) : ILabReportDispatchService
{
    public async Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string? dateBasis,
        string? search, string? dispatchStatus, string? clientType)
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
                ClientType = string.IsNullOrWhiteSpace(clientType) ? "ALL" : clientType
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
}
