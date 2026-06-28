using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IEmrConsultationApiClient
{
    Task<EmrConsultationResponse?> GetConsultationDataAsync(int opdServiceId, int doctorId);
    Task<bool> SaveConsultationAsync(object request);
}
