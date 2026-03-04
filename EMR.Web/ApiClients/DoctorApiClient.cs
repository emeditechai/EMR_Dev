using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class DoctorApiClient : IDoctorApiClient
{
    private readonly HttpClient _http;

    public DoctorApiClient(IHttpClientFactory factory)
    {
        _http = factory.CreateClient("EmrApi");
    }

    public async Task<List<DoctorListItem>> GetListAsync(int? branchId = null)
    {
        var url = branchId.HasValue
            ? $"api/doctors?branchId={branchId}"
            : "api/doctors";

        var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorListItem>>>(url);
        return response?.Data ?? new List<DoctorListItem>();
    }

    public async Task<DoctorDetail?> GetByIdAsync(int doctorId, int? branchId = null)
    {
        var url = branchId.HasValue
            ? $"api/doctors/{doctorId}?branchId={branchId}"
            : $"api/doctors/{doctorId}";

        var response = await _http.GetFromJsonAsync<ApiResponse<DoctorDetail>>(url);
        return response?.Data;
    }

    public async Task<int?> CreateAsync(DoctorCreateRequest request)
    {
        var httpResponse = await _http.PostAsJsonAsync("api/doctors", request);
        if (!httpResponse.IsSuccessStatusCode)
            return null;

        var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Success == true ? result.Data : null;
    }

    public async Task<bool> UpdateAsync(DoctorUpdateRequest request)
    {
        var httpResponse = await _http.PutAsJsonAsync($"api/doctors/{request.DoctorId}", request);
        if (!httpResponse.IsSuccessStatusCode)
            return false;

        var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<object>>();
        return result?.Success == true;
    }
}
