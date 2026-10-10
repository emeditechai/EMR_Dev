using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class DoctorIpCommissionApiClient(IHttpClientFactory factory) : IDoctorIpCommissionApiClient
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    private static string Qs(params (string Key, object? Value)[] items)
    {
        var parts = items.Where(i => i.Value != null && !(i.Value is string s && string.IsNullOrWhiteSpace(s)))
            .Select(i => $"{i.Key}={Uri.EscapeDataString(i.Value is DateTime dt ? dt.ToString("yyyy-MM-dd") : i.Value is bool b ? b.ToString().ToLowerInvariant() : i.Value!.ToString()!)}");
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

    public async Task<IEnumerable<DoctorIpCommissionPendingModel>> GetPendingAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpCommissionPendingModel>>>(
            "api/doctor-ip-commission/pending" + Qs(("branchId", branchId), ("doctorId", doctorId), ("fromDate", fromDate), ("toDate", toDate), ("companyId", companyId)));
        return res?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorIpCommissionCalculateResultModel>> CalculateAsync(DoctorIpCommissionCalculateRequestModel req)
    {
        var res = await Client.PostAsJsonAsync("api/doctor-ip-commission/calculate", req);
        await EnsureOk(res, "Failed to calculate commission.");
        return (await res.Content.ReadFromJsonAsync<ApiResponse<IEnumerable<DoctorIpCommissionCalculateResultModel>>>())?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorIpCommissionListModel>> GetListAsync(int? branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId)
    {
        var res = await Client.GetFromJsonAsync<ApiResponse<IEnumerable<DoctorIpCommissionListModel>>>(
            "api/doctor-ip-commission" + Qs(("branchId", branchId), ("doctorId", doctorId), ("fromDate", fromDate), ("toDate", toDate), ("companyId", companyId)));
        return res?.Data ?? [];
    }

    public async Task<DoctorIpCommissionDetailModel?> GetDetailAsync(long id)
    {
        var res = await Client.GetAsync($"api/doctor-ip-commission/{id}");
        if (res.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        await EnsureOk(res, "Failed to load commission detail.");
        return (await res.Content.ReadFromJsonAsync<ApiResponse<DoctorIpCommissionDetailModel>>())?.Data;
    }
}
