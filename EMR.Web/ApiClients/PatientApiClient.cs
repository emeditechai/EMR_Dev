using System.Net.Http.Json;
using System.Web;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class PatientApiClient : IPatientApiClient
{
    private readonly HttpClient _http;

    public PatientApiClient(IHttpClientFactory factory)
    {
        _http = factory.CreateClient("EmrApi");
    }

    public async Task<PagedResult<PatientListItem>> GetByBranchAsync(
        int? branchId, int page = 1, int pageSize = 20, string? search = null)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (branchId.HasValue) qs["branchId"] = branchId.ToString();
        qs["page"]     = page.ToString();
        qs["pageSize"] = pageSize.ToString();
        if (!string.IsNullOrWhiteSpace(search)) qs["search"] = search;

        var url = "api/patients?" + qs;

        var response = await _http.GetFromJsonAsync<ApiResponse<PagedResult<PatientListItem>>>(url);
        return response?.Data ?? new PagedResult<PatientListItem>();
    }

    public async Task<PatientDetail?> GetByIdAsync(int patientId)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<PatientDetail>>($"api/patients/{patientId}");
        return response?.Data;
    }

    public async Task<int?> CreateAsync(PatientCreateRequest request)
    {
        var httpResponse = await _http.PostAsJsonAsync("api/patients", request);
        if (!httpResponse.IsSuccessStatusCode)
            return null;

        var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Success == true ? result.Data : null;
    }

    public async Task<bool> UpdateAsync(PatientUpdateRequest request)
    {
        var httpResponse = await _http.PutAsJsonAsync($"api/patients/{request.PatientId}", request);
        if (!httpResponse.IsSuccessStatusCode)
            return false;

        var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<object>>();
        return result?.Success == true;
    }
}
