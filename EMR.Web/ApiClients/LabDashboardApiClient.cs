using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabDashboardApiClient : ILabDashboardApiClient
{
    private readonly HttpClient _http;

    public LabDashboardApiClient(IHttpClientFactory factory)
    {
        _http = factory.CreateClient("EmrApi");
    }

    public async Task<LabDashboardData?> GetDashboardStatsAsync(int branchId, string date)
    {
        return await _http.GetFromJsonAsync<LabDashboardData>($"api/labdashboard/stats?branchId={branchId}&date={date}");
    }
}
