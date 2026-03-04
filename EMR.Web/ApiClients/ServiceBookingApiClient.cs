using System.Net.Http.Json;
using System.Web;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class ServiceBookingApiClient(IHttpClientFactory factory) : IServiceBookingApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<ServiceBookingPagedResult> GetPagedAsync(
        int? branchId, DateOnly? fromDate, DateOnly? toDate,
        int page, int pageSize, string? search)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (branchId.HasValue)  qs["branchId"]  = branchId.ToString();
        if (fromDate.HasValue)  qs["fromDate"]   = fromDate.Value.ToString("yyyy-MM-dd");
        if (toDate.HasValue)    qs["toDate"]     = toDate.Value.ToString("yyyy-MM-dd");
        qs["page"]     = page.ToString();
        qs["pageSize"] = pageSize.ToString();
        if (!string.IsNullOrWhiteSpace(search)) qs["search"] = search;

        var url = "api/servicebookings?" + qs;
        var response = await _http.GetFromJsonAsync<ApiResponse<ServiceBookingPagedResult>>(url);
        return response?.Data ?? new ServiceBookingPagedResult();
    }

    public async Task<ServiceBookingDetail?> GetByIdAsync(int opdServiceId)
    {
        var response = await _http
            .GetFromJsonAsync<ApiResponse<ServiceBookingDetail>>($"api/servicebookings/{opdServiceId}");
        return response?.Data;
    }
}
