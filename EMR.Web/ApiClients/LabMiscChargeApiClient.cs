using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabMiscChargeApiClient(IHttpClientFactory httpClientFactory) : ILabMiscChargeApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");
    private const string Base = "api/LabMiscCharge";

    public async Task<IEnumerable<LabMiscChargeModel>> GetListAsync(bool? status = null, string? chargeType = null, string? search = null, int? companyId = null)
    {
        var q = new List<string>();
        if (status.HasValue) q.Add($"status={status.Value}");
        if (!string.IsNullOrWhiteSpace(chargeType)) q.Add($"chargeType={Uri.EscapeDataString(chargeType)}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) q.Add($"companyId={companyId.Value}");

        var response = await Client.GetAsync(q.Count > 0 ? Base + "?" + string.Join("&", q) : Base);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabMiscChargeModel>>() ?? [];
    }

    public async Task<LabMiscChargeModel?> GetByIdAsync(int id)
    {
        var response = await Client.GetAsync($"{Base}/{id}");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabMiscChargeModel>();
    }

    public async Task<int> CreateAsync(LabMiscChargeSaveRequestModel request)
    {
        var response = await Client.PostAsJsonAsync(Base, request);
        await EnsureOkAsync(response, "Failed to create the Misc Charge.");
        var result = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        return result?.TryGetValue("id", out var idObj) == true && int.TryParse(idObj?.ToString(), out var id) ? id : 0;
    }

    public async Task UpdateAsync(LabMiscChargeSaveRequestModel request) =>
        await EnsureOkAsync(await Client.PutAsJsonAsync($"{Base}/{request.Misc_Charge_ID}", request), "Failed to update the Misc Charge.");

    public async Task ToggleStatusAsync(LabMiscChargeToggleStatusRequestModel request) =>
        await EnsureOkAsync(await Client.PatchAsJsonAsync($"{Base}/{request.Misc_Charge_ID}/toggle-status", request), "Failed to change the status.");

    public async Task DeleteAsync(int id, int? userId = null) =>
        await EnsureOkAsync(await Client.DeleteAsync(userId.HasValue ? $"{Base}/{id}?userId={userId.Value}" : $"{Base}/{id}"), "Failed to delete the Misc Charge.");

    // the API's message (a validation message from the procedure) becomes the error shown on the page
    private static async Task EnsureOkAsync(HttpResponseMessage response, string fallback)
    {
        if (response.IsSuccessStatusCode) return;
        string? msg = null;
        try
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            if (err?.TryGetValue("message", out var m) == true) msg = m?.ToString();
        }
        catch { /* not JSON */ }
        throw new InvalidOperationException(string.IsNullOrWhiteSpace(msg) ? fallback : msg);
    }
}
