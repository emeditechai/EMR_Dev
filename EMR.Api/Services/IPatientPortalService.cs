using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IPatientPortalService
{
    Task<PortalDashboardSummary> GetDashboardSummaryAsync(int patientId);
    Task<IEnumerable<PortalDependent>> GetDependentsAsync(int patientId);
    Task<IEnumerable<PortalVital>> GetVitalsAsync(int patientId);
    Task<IEnumerable<PortalBooking>> GetBookingsAsync(int patientId);
    Task<IEnumerable<PortalPrescription>> GetPrescriptionsAsync(int patientId);
    Task<PortalFullProfile> GetFullProfileAsync(int patientId);
}
