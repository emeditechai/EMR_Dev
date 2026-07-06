using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IVideoConsultationService
{
    /// <summary>
    /// End-to-end orchestration: Creates Whereby room, persists record,
    /// sends Doctor email (hostUrl) and Patient email (roomUrl).
    /// </summary>
    Task CreateAndDispatchAsync(
        int opdServiceId, int doctorId, int patientId,
        DateTime appointmentDate, TimeSpan slotStartTime, TimeSpan slotEndTime,
        int graceTimeMinutes, int branchId, string createdBy);
}
