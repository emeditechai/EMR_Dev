using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models;

namespace EMR.Web.ApiClients;

public class ReportApiClient(IHttpClientFactory factory) : IReportApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<ReportApiResult<List<DailyCollectionRegisterItem>>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed)
    {
        try
        {
            var url = $"/api/reports/daily-collection?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}&isDetailed={isDetailed}";
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

    public async Task<ReportApiResult<List<PatientRegisterItem>>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly)
    {
        try
        {
            var url = $"/api/reports/patient-register?branchId={branchId}&fromDate={fromDate:yyyy-MM-dd}&toDate={toDate:yyyy-MM-dd}&dependentOnly={dependentOnly}";
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
}
