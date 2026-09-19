using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabReferenceRangeApiClient(IHttpClientFactory factory) : ILabReferenceRangeApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabReferenceRangeModel>> GetListAsync(int? testId = null, string? gender = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (testId.HasValue) query.Add($"testId={testId.Value}");
        if (!string.IsNullOrWhiteSpace(gender)) query.Add($"gender={Uri.EscapeDataString(gender)}");
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabReferenceRangeModel>>>($"api/lab-reference-ranges{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabReferenceRangeModel?> GetByIdAsync(int id, int? companyId = null)
    {
        var queryString = companyId.HasValue ? $"?companyId={companyId.Value}" : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<LabReferenceRangeModel>>($"api/lab-reference-ranges/{id}{queryString}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabReferenceRangeCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-reference-ranges", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Reference Range.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<bool> UpdateAsync(LabReferenceRangeUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-reference-ranges/{req.RefRange_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Reference Range.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int companyId = 1, int? userId = null)
    {
        var query = new List<string> { $"companyId={companyId}" };
        if (userId.HasValue) query.Add($"userId={userId.Value}");
        var queryString = "?" + string.Join("&", query);

        var res = await Client.DeleteAsync($"api/lab-reference-ranges/{id}{queryString}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Reference Range.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabReferenceRangeToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-reference-ranges/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<int> BulkSaveAsync(LabReferenceRangeBulkSaveRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-reference-ranges/bulk-save", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to bulk save Reference Ranges.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<IEnumerable<LabNumericTestOptionModel>> GetNumericTestsAsync(int companyId = 1)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabNumericTestOptionModel>>>($"api/lab-reference-ranges/numeric-tests?companyId={companyId}");
        return res?.Data ?? [];
    }
}
