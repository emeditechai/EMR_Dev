using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabRateCardApiClient
{
    Task<IEnumerable<LabRateCardHeaderModel>> GetListAsync(string? rateType, int? branchId, bool? status, int companyId = 1);
    Task<LabRateCardFullModel?> GetByIdAsync(int id);
    Task<int> SaveAsync(LabRateCardSaveRequestModel req);
    Task<bool> ToggleStatusAsync(LabRateCardToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabItemModel>> GetAllItemsAsync(int companyId = 1);
}

public class LabRateCardApiClient(IHttpClientFactory httpClientFactory) : ILabRateCardApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<IEnumerable<LabRateCardHeaderModel>> GetListAsync(string? rateType, int? branchId, bool? status, int companyId = 1)
    {
        var qs = new List<string> { $"companyId={companyId}" };
        if (!string.IsNullOrEmpty(rateType)) qs.Add($"rateType={Uri.EscapeDataString(rateType)}");
        if (branchId.HasValue) qs.Add($"branchId={branchId.Value}");
        if (status.HasValue) qs.Add($"status={status.Value.ToString().ToLower()}");

        var url = $"api/lab-rate-cards?{string.Join("&", qs)}";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabRateCardHeaderModel>>>(url);
        return res?.Data ?? [];
    }

    public async Task<LabRateCardFullModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<LabRateCardFullModel>>($"api/lab-rate-cards/{id}");
        return res?.Data;
    }

    public async Task<int> SaveAsync(LabRateCardSaveRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/lab-rate-cards", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to save Lab Rate Card.");
        }
        var successResponse = await res.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return successResponse?.Data ?? 0;
    }

    public async Task<bool> ToggleStatusAsync(LabRateCardToggleStatusRequestModel req)
    {
        var res = await Client.PatchAsJsonAsync($"api/lab-rate-cards/{req.RateCard_ID}/status", req);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to toggle status.");
        }
        return true;
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        var qs = userId.HasValue ? $"?userId={userId}" : "";
        var res = await Client.DeleteAsync($"api/lab-rate-cards/{id}{qs}");
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to delete Lab Rate Card.");
        }
        return true;
    }

    public async Task<IEnumerable<LabItemModel>> GetAllItemsAsync(int companyId = 1)
    {
        var url = $"api/lab-rate-cards/items?companyId={companyId}";
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<LabItemModel>>>(url);
        return res?.Data ?? [];
    }
}
