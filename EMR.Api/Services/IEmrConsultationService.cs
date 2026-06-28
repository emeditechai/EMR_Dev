using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IEmrConsultationService
{
    Task<EmrConsultationResponse?> GetConsultationDataAsync(int opdServiceId, int doctorId);
    Task<bool> SaveConsultationAsync(SaveConsultationRequest req);
}
