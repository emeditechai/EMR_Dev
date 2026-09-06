using System;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabDashboardService
{
    Task<LabDashboardData> GetDashboardStatsAsync(int branchId, DateTime date);
}
