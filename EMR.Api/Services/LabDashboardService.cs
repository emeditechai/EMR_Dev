using System;
using System.Data;
using System.Linq;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabDashboardService(IDbConnectionFactory db) : ILabDashboardService
{
    public async Task<LabDashboardData> GetDashboardStatsAsync(int branchId, DateTime date)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "usp_Api_LAB_Dashboard_GetStats",
            new { BranchId = branchId, Date = date.Date },
            commandType: CommandType.StoredProcedure);

        var data = new LabDashboardData();

        data.Summary = await multi.ReadSingleOrDefaultAsync<LabDashboardSummary>() ?? new LabDashboardSummary();
        data.StatusBreakdown = (await multi.ReadAsync<LabStatusBreakdownDto>()).ToList();
        data.TopInvestigations = (await multi.ReadAsync<LabTopTestDto>()).ToList();
        data.CategoryDistribution = (await multi.ReadAsync<LabCategoryDistributionDto>()).ToList();
        data.PatientOrders = (await multi.ReadAsync<LabDashboardPatientOrderDto>()).ToList();

        return data;
    }
}
