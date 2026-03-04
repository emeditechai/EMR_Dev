using System.Net.Http.Json;
using System.Web;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class PaymentSummaryApiClient(IHttpClientFactory factory) : IPaymentSummaryApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<PaymentSummaryResult?> GetAsync(string moduleCode, int moduleRefId)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        qs["moduleCode"]  = moduleCode;
        qs["moduleRefId"] = moduleRefId.ToString();

        var url = "api/paymentsummary?" + qs;
        var response = await _http.GetFromJsonAsync<ApiResponse<PaymentSummaryResult>>(url);
        return response?.Data;
    }
}
