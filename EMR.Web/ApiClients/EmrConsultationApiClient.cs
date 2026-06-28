using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class EmrConsultationApiClient : IEmrConsultationApiClient
{
    private readonly HttpClient _http;

    public EmrConsultationApiClient(IHttpClientFactory factory)
    {
        _http = factory.CreateClient("EmrApi");
    }

    public async Task<EmrConsultationResponse?> GetConsultationDataAsync(int opdServiceId, int doctorId)
    {
        var response = await _http.GetAsync($"api/emrconsultations/{opdServiceId}/doctor/{doctorId}");
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var res = await response.Content.ReadFromJsonAsync<ApiResponse<EmrConsultationResponse>>();
        return res?.Data;
    }

    public async Task<bool> SaveConsultationAsync(object request)
    {
        var response = await _http.PostAsJsonAsync("api/emrconsultations", request);
        return response.IsSuccessStatusCode;
    }
}
