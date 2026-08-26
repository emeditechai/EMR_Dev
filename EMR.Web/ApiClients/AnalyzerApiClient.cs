using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class AnalyzerApiClient(HttpClient http, ILogger<AnalyzerApiClient> logger) : IAnalyzerApiClient
{
    public async Task<List<AnalyzerListItem>> GetListAsync(int? departmentId = null,
        string? interfaceProtocol = null,
        bool? status = null,
        string? search = null)
    {
        try
        {
            var query = new List<string>();
            if (departmentId.HasValue) query.Add($"departmentId={departmentId.Value}");
            if (!string.IsNullOrWhiteSpace(interfaceProtocol)) query.Add($"interfaceProtocol={Uri.EscapeDataString(interfaceProtocol)}");
            if (status.HasValue) query.Add($"status={status.Value}");
            if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");

            var url = "/api/analyzers" + (query.Count > 0 ? "?" + string.Join("&", query) : "");
            var result = await http.GetFromJsonAsync<List<AnalyzerListItem>>(url);
            return result ?? new List<AnalyzerListItem>();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to get analyzers list from API.");
            return new List<AnalyzerListItem>();
        }
    }

    public async Task<AnalyzerDetail?> GetByIdAsync(int id)
    {
        try
        {
            return await http.GetFromJsonAsync<AnalyzerDetail>($"/api/analyzers/{id}");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to get analyzer #{Id} from API.", id);
            return null;
        }
    }

    public async Task<int> CreateAsync(AnalyzerSaveRequest request)
    {
        try
        {
            var response = await http.PostAsJsonAsync("/api/analyzers", request);
            if (response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadFromJsonAsync<CreateResponse>();
                return body?.Id ?? 0;
            }
            var err = await response.Content.ReadAsStringAsync();
            logger.LogWarning("Create analyzer failed: {StatusCode} {Error}", response.StatusCode, err);
            return 0;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Exception creating analyzer.");
            return 0;
        }
    }

    public async Task<bool> UpdateAsync(AnalyzerSaveRequest request)
    {
        try
        {
            var response = await http.PutAsJsonAsync($"/api/analyzers/{request.Analyzer_ID}", request);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Exception updating analyzer #{Id}.", request.Analyzer_ID);
            return false;
        }
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        try
        {
            var url = $"/api/analyzers/{id}/toggle-status" + (userId.HasValue ? $"?userId={userId.Value}" : "");
            var response = await http.PostAsync(url, null);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Exception toggling analyzer #{Id} status.", id);
            return false;
        }
    }

    public async Task<bool> DeleteAsync(int id)
    {
        try
        {
            var response = await http.DeleteAsync($"/api/analyzers/{id}");
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Exception deleting analyzer #{Id}.", id);
            return false;
        }
    }

    private class CreateResponse
    {
        public int Id { get; set; }
        public string? Message { get; set; }
    }
}
