using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models;

namespace EMR.Web.ApiClients;

public class ReportApiClient(IHttpClientFactory factory) : IReportApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<ReportApiResult<List<DailyCollectionRegisterItem>>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed, int? companyId = null)
    {
        try
        {
            var url = $"/api/reports/daily-collection?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}&isDetailed={isDetailed}";
            if (companyId.HasValue && companyId.Value > 0)
            {
                url += $"&companyId={companyId.Value}";
            }
            var response = await _http.GetAsync(url);
            
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<List<DailyCollectionRegisterItem>>();
                return ReportApiResult<List<DailyCollectionRegisterItem>>.SuccessResult(data ?? new List<DailyCollectionRegisterItem>());
            }
            return ReportApiResult<List<DailyCollectionRegisterItem>>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<List<DailyCollectionRegisterItem>>.FailureResult(ex.Message);
        }
    }

    public async Task<ReportApiResult<List<PatientRegisterItem>>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly, int? companyId = null)
    {
        try
        {
            var url = $"/api/reports/patient-register?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}&dependentOnly={dependentOnly}";
            if (companyId.HasValue && companyId.Value > 0)
            {
                url += $"&companyId={companyId.Value}";
            }
            var response = await _http.GetAsync(url);
            
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<List<PatientRegisterItem>>();
                return ReportApiResult<List<PatientRegisterItem>>.SuccessResult(data ?? new List<PatientRegisterItem>());
            }
            return ReportApiResult<List<PatientRegisterItem>>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<List<PatientRegisterItem>>.FailureResult(ex.Message);
        }
    }

    public async Task<ReportApiResult<B2CCollectionRegisterResult>> GetLabB2CCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate,
        int? paymentMethodId, int? collectedBy, string? search, int userId, bool isAdmin, bool isSuperAdmin)
    {
        try
        {
            var url = $"/api/reports/lab/b2c-collection-register?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}";
            if (paymentMethodId is > 0) url += $"&paymentMethodId={paymentMethodId}";
            if (collectedBy is > 0) url += $"&collectedBy={collectedBy}";
            if (!string.IsNullOrWhiteSpace(search)) url += $"&search={Uri.EscapeDataString(search.Trim())}";
            url += $"&userId={userId}&isAdmin={isAdmin.ToString().ToLowerInvariant()}&isSuperAdmin={isSuperAdmin.ToString().ToLowerInvariant()}";

            var response = await _http.GetAsync(url);
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<B2CCollectionRegisterResult>();
                return ReportApiResult<B2CCollectionRegisterResult>.SuccessResult(data ?? new B2CCollectionRegisterResult());
            }
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                var denied = await response.Content.ReadFromJsonAsync<Dictionary<string, string>>();
                return ReportApiResult<B2CCollectionRegisterResult>.FailureResult(denied?.GetValueOrDefault("message") ?? "You do not have access to this report.");
            }
            return ReportApiResult<B2CCollectionRegisterResult>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<B2CCollectionRegisterResult>.FailureResult(ex.Message);
        }
    }

    public async Task<ReportApiResult<DiscountRegisterResult>> GetLabDiscountRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, string? billingType,
        int? approvedBy, int? enteredBy, string? search, int userId, bool isAdmin, bool isSuperAdmin)
    {
        try
        {
            var url = $"/api/reports/lab/discount-register?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}";
            if (!string.IsNullOrWhiteSpace(billingType)) url += $"&billingType={Uri.EscapeDataString(billingType)}";
            if (approvedBy is > 0) url += $"&approvedBy={approvedBy}";
            if (enteredBy is > 0) url += $"&enteredBy={enteredBy}";
            if (!string.IsNullOrWhiteSpace(search)) url += $"&search={Uri.EscapeDataString(search.Trim())}";
            url += $"&userId={userId}&isAdmin={isAdmin.ToString().ToLowerInvariant()}&isSuperAdmin={isSuperAdmin.ToString().ToLowerInvariant()}";

            var response = await _http.GetAsync(url);
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<DiscountRegisterResult>();
                return ReportApiResult<DiscountRegisterResult>.SuccessResult(data ?? new DiscountRegisterResult());
            }
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                var denied = await response.Content.ReadFromJsonAsync<Dictionary<string, string>>();
                return ReportApiResult<DiscountRegisterResult>.FailureResult(denied?.GetValueOrDefault("message") ?? "You do not have access to this report.");
            }
            return ReportApiResult<DiscountRegisterResult>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<DiscountRegisterResult>.FailureResult(ex.Message);
        }
    }

    public async Task<ReportApiResult<string>> RunLabReportRawAsync(string report, IDictionary<string, string?> query)
    {
        try
        {
            var qs = string.Join("&", query.Where(kv => !string.IsNullOrWhiteSpace(kv.Value))
                                           .Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value!)}"));
            var response = await _http.GetAsync($"/api/reports/lab/run/{Uri.EscapeDataString(report)}?{qs}");
            if (response.IsSuccessStatusCode)
                return ReportApiResult<string>.SuccessResult(await response.Content.ReadAsStringAsync());
            if (response.StatusCode is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.BadRequest or System.Net.HttpStatusCode.NotFound)
            {
                var body = await response.Content.ReadFromJsonAsync<Dictionary<string, string>>();
                return ReportApiResult<string>.FailureResult(body?.GetValueOrDefault("message") ?? "You do not have access to this report.");
            }
            return ReportApiResult<string>.FailureResult($"Failed with status {response.StatusCode}");
        }
        catch (Exception ex)
        {
            return ReportApiResult<string>.FailureResult(ex.Message);
        }
    }
}
