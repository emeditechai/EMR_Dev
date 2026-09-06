using System.Threading.Tasks;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabDashboardApiClient
{
    Task<LabDashboardData?> GetDashboardStatsAsync(int branchId, string date);
}
