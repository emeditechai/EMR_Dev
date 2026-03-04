using System.Net.Http.Json;
using System.Web;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class VitalApiClient : IVitalApiClient
{
    private readonly HttpClient _http;

    public VitalApiClient(IHttpClientFactory factory)
    {
        _http = factory.CreateClient("EmrApi");
    }

    // ── History ───────────────────────────────────────────────────────────────

    public async Task<VitalHistoryResult> GetHistoryAsync(int patientId, int page = 1, int pageSize = 10)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        qs["patientId"] = patientId.ToString();
        qs["page"]      = page.ToString();
        qs["pageSize"]  = pageSize.ToString();

        var response = await _http.GetFromJsonAsync<ApiResponse<VitalHistoryResult>>(
            "api/vitals?" + qs);

        return response?.Data ?? new VitalHistoryResult();
    }

    // ── Get by ID ─────────────────────────────────────────────────────────────

    public async Task<VitalRow?> GetByIdAsync(int vitalId)
    {
        try
        {
            var response = await _http.GetFromJsonAsync<ApiResponse<VitalRow>>(
                $"api/vitals/{vitalId}");
            return response?.Data;
        }
        catch (HttpRequestException) { return null; }
    }

    // ── Latest ────────────────────────────────────────────────────────────────

    public async Task<VitalRow?> GetLatestAsync(int patientId)
    {
        try
        {
            var response = await _http.GetFromJsonAsync<ApiResponse<VitalRow>>(
                $"api/vitals/latest/{patientId}");
            return response?.Data;
        }
        catch (HttpRequestException) { return null; }
    }

    // ── Print data ────────────────────────────────────────────────────────────

    public async Task<VitalPrintData?> GetPrintDataAsync(int patientId, int? branchId = null)
    {
        var url = $"api/vitals/print/{patientId}";
        if (branchId.HasValue) url += $"?branchId={branchId}";

        try
        {
            var response = await _http.GetFromJsonAsync<ApiResponse<VitalPrintData>>(url);
            return response?.Data;
        }
        catch (HttpRequestException) { return null; }
    }

    // ── Create ────────────────────────────────────────────────────────────────

    public async Task<int?> CreateAsync(VitalCreateRequest request)
    {
        var httpResponse = await _http.PostAsJsonAsync("api/vitals", request);
        if (!httpResponse.IsSuccessStatusCode) return null;

        var result = await httpResponse.Content
            .ReadFromJsonAsync<ApiResponse<CreatedVitalPayload>>();

        return result?.Success == true ? result.Data?.PatientVitalId : null;
    }

    // ── Update ────────────────────────────────────────────────────────────────

    public async Task<bool> UpdateAsync(VitalUpdateRequest request)
    {
        var httpResponse = await _http.PutAsJsonAsync(
            $"api/vitals/{request.PatientVitalId}", request);

        if (!httpResponse.IsSuccessStatusCode) return false;

        var result = await httpResponse.Content
            .ReadFromJsonAsync<ApiResponse<object>>();

        return result?.Success == true;
    }

    // ── Delete ────────────────────────────────────────────────────────────────

    public async Task<bool> DeleteAsync(int vitalId, int deletedByUserId)
    {
        var httpResponse = await _http.DeleteAsync(
            $"api/vitals/{vitalId}?deletedByUserId={deletedByUserId}");

        if (!httpResponse.IsSuccessStatusCode) return false;

        var result = await httpResponse.Content
            .ReadFromJsonAsync<ApiResponse<object>>();

        return result?.Success == true;
    }

    // ── Private helper class ──────────────────────────────────────────────────

    private class CreatedVitalPayload { public int PatientVitalId { get; set; } }
}
