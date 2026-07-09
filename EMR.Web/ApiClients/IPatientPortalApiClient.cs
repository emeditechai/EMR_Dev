using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IPatientPortalApiClient
{
    Task<PortalFullProfile?> GetFullProfileAsync(int patientId);
    Task<PortalDashboardSummary?> GetDashboardSummaryAsync(int patientId);
    Task<List<PortalDependent>> GetDependentsAsync(int patientId);
    Task<List<PortalVital>> GetVitalsAsync(int patientId);
    Task<List<PortalBooking>> GetBookingsAsync(int patientId);
    Task<List<PortalPrescription>> GetPrescriptionsAsync(int patientId);
}
