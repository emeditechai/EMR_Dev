using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public class LabReportDispatchApiClient(IHttpClientFactory httpClientFactory) : ILabReportDispatchApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<LabReportDispatchResult> GetDashboardAsync(
        int branchId, DateTime? fromDate, DateTime? toDate, string dateBasis,
        string? search, string dispatchStatus, string clientType, int? createdBy = null)
    {
        var q = new List<string>
        {
            $"branchId={branchId}",
            $"dateBasis={Uri.EscapeDataString(dateBasis)}",
            $"dispatchStatus={Uri.EscapeDataString(dispatchStatus)}",
            $"clientType={Uri.EscapeDataString(clientType)}"
        };
        if (fromDate.HasValue) q.Add($"fromDate={Uri.EscapeDataString(fromDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (toDate.HasValue) q.Add($"toDate={Uri.EscapeDataString(toDate.Value.ToString("yyyy-MM-ddTHH:mm:ss"))}");
        if (!string.IsNullOrWhiteSpace(search)) q.Add($"search={Uri.EscapeDataString(search.Trim())}");
        if (createdBy is > 0) q.Add($"createdBy={createdBy.Value}");

        var response = await Client.GetAsync($"api/lab-report-dispatch/dashboard?{string.Join("&", q)}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabReportDispatchResult>() ?? new LabReportDispatchResult();
    }

    public async Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId)
    {
        var response = await Client.GetAsync($"api/lab-report-dispatch/bill-tests/{labOrderId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabReportDispatchTestDto>>() ?? [];
    }

    public async Task<List<LabDuePrintStateDto>> GetDuePrintStatesAsync(IEnumerable<int> labOrderIds)
    {
        var ids = string.Join(",", labOrderIds.Where(i => i > 0).Distinct());
        if (ids.Length == 0) return [];
        var response = await Client.GetAsync($"api/lab-report-dispatch/due-print/states?ids={ids}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<List<LabDuePrintStateDto>>() ?? [];
    }

    public async Task<LabDuePrintSubmitResult> SubmitDuePrintAsync(int labOrderId, int userId, string? reason)
    {
        var response = await Client.PostAsJsonAsync("api/lab-report-dispatch/due-print/submit",
            new LabDuePrintSubmitRequest { LabOrderId = labOrderId, UserId = userId, Reason = reason });
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<LabDuePrintSubmitResult>() ?? new LabDuePrintSubmitResult { ErrorMessage = "No answer from the service." };
    }
}
