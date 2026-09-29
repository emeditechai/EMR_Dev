using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class DoctorIpApiClient(IHttpClientFactory factory) : IDoctorIpApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    private static string Qs(params (string Key, object? Value)[] items)
    {
        var parts = items.Where(i => i.Value != null && !(i.Value is string s && string.IsNullOrWhiteSpace(s)))
            .Select(i => $"{i.Key}={Uri.EscapeDataString(i.Value is bool b ? b.ToString().ToLowerInvariant() : i.Value!.ToString()!)}");
        var q = string.Join("&", parts);
        return q.Length > 0 ? "?" + q : "";
    }

    private static async Task EnsureOk(HttpResponseMessage res, string fallback)
    {
        if (res.IsSuccessStatusCode) return;
        ApiResponse<object>? err = null;
        try { err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>(); } catch { }
        throw new InvalidOperationException(err?.Message ?? fallback);
    }

    public async Task<IEnumerable<DoctorIpListModel>> GetListAsync(int? companyId, int? branchId, bool? status = null, string? search = null)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpListModel>>>(
            "api/doctor-ip" + Qs(("companyId", companyId), ("branchId", branchId), ("status", status), ("search", search)));
        return res?.Data ?? [];
    }

    public async Task<DoctorIpDetailModel?> GetByIdAsync(int id)
    {
        var res = await Client.GetAsync($"api/doctor-ip/{id}");
        if (res.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        await EnsureOk(res, "Failed to load Doctor IP.");
        return (await res.Content.ReadFromJsonAsync<ApiResponse<DoctorIpDetailModel>>())?.Data;
    }

    public async Task<int> SaveAsync(DoctorIpSaveRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/doctor-ip", req);
        await EnsureOk(res, "Failed to save Doctor IP.");
        return (await res.Content.ReadFromJsonAsync<ApiResponse<int>>())?.Data ?? 0;
    }

    public async Task ToggleStatusAsync(DoctorIpToggleStatusRequestModel req)
        => await EnsureOk(await Client.PostAsJsonAsync($"api/doctor-ip/{req.Doctor_IP_Hdr_ID}/toggle-status", req), "Failed to change status.");

    public async Task DeleteAsync(int id, int? userId)
        => await EnsureOk(await Client.DeleteAsync($"api/doctor-ip/{id}" + Qs(("userId", userId))), "Failed to delete Doctor IP.");

    public async Task<IEnumerable<DoctorIpSpecialityModel>> GetSpecialitiesAsync(int? companyId)
        => (await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpSpecialityModel>>>("api/doctor-ip/specialities" + Qs(("companyId", companyId))))?.Data ?? [];

    public async Task<IEnumerable<DoctorIpLookupModel>> GetDoctorsAsync(int specialityId, int? companyId)
        => (await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpLookupModel>>>("api/doctor-ip/doctors" + Qs(("specialityId", specialityId), ("companyId", companyId))))?.Data ?? [];

    public async Task<IEnumerable<DoctorIpItemModel>> GetItemsAsync(int? companyId)
        => (await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpItemModel>>>("api/doctor-ip/items" + Qs(("companyId", companyId))))?.Data ?? [];

    public async Task<DoctorIpAccessStatusModel> GetAccessStatusAsync(int companyId, int userId)
        => (await Client.GetFromJsonAsync<ApiResponse<DoctorIpAccessStatusModel>>("api/doctor-ip/access/status" + Qs(("companyId", companyId), ("userId", userId))))?.Data
           ?? new DoctorIpAccessStatusModel();

    public async Task<DoctorIpVerifyCodeResultModel> VerifyAccessCodeAsync(DoctorIpVerifyCodeRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/doctor-ip/access/verify", req);
        await EnsureOk(res, "Could not verify the access code.");
        return (await res.Content.ReadFromJsonAsync<ApiResponse<DoctorIpVerifyCodeResultModel>>())?.Data ?? new DoctorIpVerifyCodeResultModel { Result = "INVALID" };
    }

    public async Task SetAccessCodeAsync(DoctorIpSetCodeRequestModel req)
        => await EnsureOk(await Client.PostAsJsonAsync("api/doctor-ip/access/code", req), "Failed to update the access code.");
}
