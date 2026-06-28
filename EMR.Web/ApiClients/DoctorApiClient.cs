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

    public async Task<List<DoctorListItem>> GetListAsync(int? branchId = null, string? searchQuery = null)
    {
        var url = "api/doctors";
        var queryParams = new List<string>();
        
        if (branchId.HasValue)
            queryParams.Add($"branchId={branchId.Value}");
            
        if (!string.IsNullOrEmpty(searchQuery))
            queryParams.Add($"searchQuery={Uri.EscapeDataString(searchQuery)}");
            
        if (queryParams.Any())
            url += "?" + string.Join("&", queryParams);

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

    public async Task<DoctorListItem?> GetLinkedDoctorAsync(int userId, string? email, string? displayName)
    {
        var url = $"api/doctors/linked?userId={userId}";
        if (!string.IsNullOrEmpty(email)) url += $"&email={Uri.EscapeDataString(email)}";
        if (!string.IsNullOrEmpty(displayName)) url += $"&displayName={Uri.EscapeDataString(displayName)}";

        var response = await _http.GetAsync(url);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var res = await response.Content.ReadFromJsonAsync<ApiResponse<DoctorListItem>>();
        return res?.Data;
    }
}
