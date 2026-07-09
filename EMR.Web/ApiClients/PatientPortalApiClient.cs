using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class PatientPortalApiClient(IHttpClientFactory httpClientFactory) : IPatientPortalApiClient
{
    private readonly HttpClient _client = httpClientFactory.CreateClient("EmrApi");

    public async Task<PortalFullProfile?> GetFullProfileAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<PortalFullProfile>>($"api/patientportal/{patientId}/fullprofile");
        return response?.Data;
    }

    public async Task<PortalDashboardSummary?> GetDashboardSummaryAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<PortalDashboardSummary>>($"api/patientportal/{patientId}/dashboard");
        return response?.Data;
    }

    public async Task<List<PortalDependent>> GetDependentsAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<List<PortalDependent>>>($"api/patientportal/{patientId}/dependents");
        return response?.Data ?? new List<PortalDependent>();
    }

    public async Task<List<PortalVital>> GetVitalsAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<List<PortalVital>>>($"api/patientportal/{patientId}/vitals");
        return response?.Data ?? new List<PortalVital>();
    }

    public async Task<List<PortalBooking>> GetBookingsAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<List<PortalBooking>>>($"api/patientportal/{patientId}/bookings");
        return response?.Data ?? new List<PortalBooking>();
    }

    public async Task<List<PortalPrescription>> GetPrescriptionsAsync(int patientId)
    {
        var response = await _client.GetFromJsonAsync<ApiResponse<List<PortalPrescription>>>($"api/patientportal/{patientId}/prescriptions");
        return response?.Data ?? new List<PortalPrescription>();
    }
}
