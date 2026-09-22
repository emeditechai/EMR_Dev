using System.Text.Json;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public class LabDefaultSignatoryApiClient(IHttpClientFactory httpClientFactory) : ILabDefaultSignatoryApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<LabDefaultSignatoryListResult> GetListAsync(int branchId, int? companyId)
    {
        var url = $"api/lab-default-signatory/list?branchId={branchId}" + (companyId.HasValue ? $"&companyId={companyId}" : "");
        var response = await Client.GetAsync(url);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabDefaultSignatoryListResult>() ?? new LabDefaultSignatoryListResult();
    }

    public async Task<(int Saved, string? Error)> SaveAsync(LabDefaultSignatorySaveRequest request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-default-signatory/save", request);
        if (response.IsSuccessStatusCode)
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return (doc.RootElement.TryGetProperty("savedCount", out var c) ? c.GetInt32() : 0, null);
        }

        if ((int)response.StatusCode == 400)
        {
            try
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (doc.RootElement.TryGetProperty("message", out var m)) return (0, m.GetString());
            }
            catch (JsonException) { }
            return (0, "The configuration was rejected.");
        }

        response.EnsureSuccessStatusCode();
        return (0, "Unexpected response.");
    }
}
