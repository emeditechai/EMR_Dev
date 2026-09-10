using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabSampleRejectionReasonApiClient(IHttpClientFactory httpClientFactory, ILogger<LabSampleRejectionReasonApiClient> logger) : ILabSampleRejectionReasonApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabSampleRejectionReasonModel>> GetListAsync(bool? status = null, int? sampleTypeId = null, string? search = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (status.HasValue) queryParams.Add($"status={status.Value}");
        if (sampleTypeId.HasValue) queryParams.Add($"sampleTypeId={sampleTypeId.Value}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/LabSampleRejectionReason";
        if (queryParams.Any()) url += "?" + string.Join("&", queryParams);

        var response = await Client.GetAsync(url);
        response.EnsureSuccessStatusCode();

        return await response.Content.ReadFromJsonAsync<IEnumerable<LabSampleRejectionReasonModel>>() ?? [];
    }

    public async Task<LabSampleRejectionReasonModel?> GetByIdAsync(int id)
    {
        var response = await Client.GetAsync($"api/LabSampleRejectionReason/{id}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabSampleRejectionReasonModel>();
    }

    public async Task<int> CreateAsync(LabSampleRejectionReasonCreateRequestModel request)
    {
        var response = await Client.PostAsJsonAsync("api/LabSampleRejectionReason", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to create Lab Sample Rejection Reason.";
            throw new InvalidOperationException(msg);
        }

        var result = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        if (result?.TryGetValue("id", out var idObj) == true && int.TryParse(idObj?.ToString(), out var id))
        {
            return id;
        }

        return 0;
    }

    public async Task UpdateAsync(LabSampleRejectionReasonUpdateRequestModel request)
    {
        var response = await Client.PutAsJsonAsync($"api/LabSampleRejectionReason/{request.Reason_ID}", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to update Lab Sample Rejection Reason.";
            throw new InvalidOperationException(msg);
        }
    }

    public async Task ToggleStatusAsync(LabSampleRejectionReasonToggleStatusRequestModel request)
    {
        var response = await Client.PatchAsJsonAsync($"api/LabSampleRejectionReason/{request.Reason_ID}/toggle-status", request);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to toggle status.";
            throw new InvalidOperationException(msg);
        }
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        var url = $"api/LabSampleRejectionReason/{id}";
        if (userId.HasValue) url += $"?userId={userId.Value}";

        var response = await Client.DeleteAsync(url);
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            var msg = err?.TryGetValue("message", out var m) == true ? m?.ToString() : "Failed to delete Lab Sample Rejection Reason.";
            throw new InvalidOperationException(msg);
        }
    }
}
