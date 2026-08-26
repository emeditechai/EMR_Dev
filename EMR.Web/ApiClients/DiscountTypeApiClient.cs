using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class DiscountTypeApiClient : IDiscountTypeApiClient
{
    private readonly HttpClient httpClient;

    public DiscountTypeApiClient(IHttpClientFactory factory)
    {
        httpClient = factory.CreateClient("EmrApi");
    }
    public async Task<IEnumerable<DiscountTypeListItemViewModel>> GetListAsync(int? branchId = null, bool? status = null, string? search = null, int? companyId = null)
    {
        var query = new List<string>();
        if (branchId.HasValue) query.Add($"branchId={branchId.Value}");
        if (status.HasValue) query.Add($"status={status.Value}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) query.Add($"companyId={companyId.Value}");

        var url = "api/discounttypes" + (query.Count > 0 ? "?" + string.Join("&", query) : "");
        return await httpClient.GetFromJsonAsync<IEnumerable<DiscountTypeListItemViewModel>>(url) ?? [];
    }

    public async Task<DiscountTypeFormViewModel?> GetByIdAsync(int id)
    {
        return await httpClient.GetFromJsonAsync<DiscountTypeFormViewModel>($"api/discounttypes/{id}");
    }

    public async Task<int> CreateAsync(DiscountTypeFormViewModel model, int userId, int? companyId, int? branchId)
    {
        var payload = new 
        {
            model.DiscountTypeName,
            model.DiscountFlag,
            model.PercentageFrom,
            model.PercentageTo,
            model.DiscountAmount,
            model.IsActive,
            CompanyId = companyId,
            BranchId = branchId,
            UserId = userId
        };
        var response = await httpClient.PostAsJsonAsync("api/discounttypes", payload);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<int>();
    }

    public async Task UpdateAsync(DiscountTypeFormViewModel model, int userId, int? companyId, int? branchId)
    {
        var payload = new 
        {
            model.DiscountTypeId,
            model.DiscountTypeName,
            model.DiscountFlag,
            model.PercentageFrom,
            model.PercentageTo,
            model.DiscountAmount,
            model.IsActive,
            CompanyId = companyId,
            BranchId = branchId,
            UserId = userId
        };
        var response = await httpClient.PutAsJsonAsync($"api/discounttypes/{model.DiscountTypeId}", payload);
        response.EnsureSuccessStatusCode();
    }

    public async Task DeleteAsync(int id)
    {
        var response = await httpClient.DeleteAsync($"api/discounttypes/{id}");
        response.EnsureSuccessStatusCode();
    }
}
