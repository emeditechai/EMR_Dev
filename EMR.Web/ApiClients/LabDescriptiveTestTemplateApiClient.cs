using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabDescriptiveTestTemplateApiClient(IHttpClientFactory factory) : ILabDescriptiveTestTemplateApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabDescriptiveTestTemplateModel>> GetListAsync(bool? status = null, string? search = null, int? testId = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (testId.HasValue) query.Add($"testId={testId.Value}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabDescriptiveTestTemplateModel>>>($"api/lab-descriptive-test-templates{queryString}");
        return res?.Data ?? [];
    }

    public async Task<LabDescriptiveTestTemplateModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabDescriptiveTestTemplateModel>>($"api/lab-descriptive-test-templates/{id}");
        return res?.Data;
    }

    public async Task<int> CreateAsync(LabDescriptiveTestTemplateCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-descriptive-test-templates", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create Descriptive Test Template.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return body?.Data ?? 0;
    }

    public async Task<List<int>> BatchCreateAsync(LabDescriptiveTestTemplateBatchCreateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-descriptive-test-templates/batch", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to create template sections.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<List<int>>>();
        return body?.Data ?? [];
    }

    public async Task<bool> UpdateAsync(LabDescriptiveTestTemplateUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync($"api/lab-descriptive-test-templates/{req.Template_ID}", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update Descriptive Test Template.");
        }
        return true;
    }

    public async Task<bool> ToggleStatusAsync(LabDescriptiveTestTemplateToggleStatusRequestModel req)
    {
        var res = await Client.PostAsJsonAsync($"api/lab-descriptive-test-templates/{req.Template_ID}/toggle-status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        var res = await Client.DeleteAsync($"api/lab-descriptive-test-templates/{id}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Descriptive Test Template.");
        }
        return true;
    }

    public async Task<IEnumerable<LabDescriptiveTestTemplateModel>> GetByTestIdAsync(int testId)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabDescriptiveTestTemplateModel>>>($"api/lab-descriptive-test-templates/by-test/{testId}");
        return res?.Data ?? [];
    }

    public async Task<bool> BatchUpdateAsync(LabDescriptiveTestTemplateBatchUpdateRequestModel req)
    {
        var res = await Client.PutAsJsonAsync("api/lab-descriptive-test-templates/batch", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to update template sections.");
        }
        return true;
    }

    public async Task<IEnumerable<LabDescriptiveTestTemplateGroupedModel>> GetGroupedListAsync(bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (status.HasValue) query.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabDescriptiveTestTemplateGroupedModel>>>($"api/lab-descriptive-test-templates/grouped{queryString}");
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<RadiologyTestItemModel>> GetRadiologyTestsAsync(int? companyId = null, string? search = null)
    {
        var query = new List<string>();
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");

        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : "";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<RadiologyTestItemModel>>>($"api/lab-descriptive-test-templates/radiology-tests{queryString}");
        return res?.Data ?? [];
    }
}
