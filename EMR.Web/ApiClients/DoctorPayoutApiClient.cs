using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>OPD doctor payout (api/doctor-payouts, SQLScripts/2213): JSON passed through to the workbench page.</summary>
public interface IDoctorPayoutApiClient
{
    Task<ReportApiResult<string>> GetAsync(string path, IDictionary<string, string?> query);
    Task<ReportApiResult<string>> PostAsync(string path, object payload);
}

public class DoctorPayoutApiClient(IHttpClientFactory factory) : IDoctorPayoutApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<ReportApiResult<string>> GetAsync(string path, IDictionary<string, string?> query)
    {
        var qs = string.Join("&", query.Where(kv => !string.IsNullOrWhiteSpace(kv.Value))
                                       .Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value!)}"));
        return await ReadAsync(() => _http.GetAsync($"/api/doctor-payouts/{path}?{qs}"));
    }

    public Task<ReportApiResult<string>> PostAsync(string path, object payload) =>
        ReadAsync(() => _http.PostAsJsonAsync($"/api/doctor-payouts/{path}", payload));

    private static async Task<ReportApiResult<string>> ReadAsync(Func<Task<HttpResponseMessage>> send)
    {
        try
        {
            var response = await send();
            if (response.IsSuccessStatusCode)
                return ReportApiResult<string>.SuccessResult(await response.Content.ReadAsStringAsync());
            if (response.StatusCode is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.BadRequest or System.Net.HttpStatusCode.NotFound)
            {
                var body = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
                return ReportApiResult<string>.FailureResult(body?.GetValueOrDefault("message")?.ToString() ?? "The request was not accepted.");
            }
            return ReportApiResult<string>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<string>.FailureResult(ex.Message);
        }
    }
}
