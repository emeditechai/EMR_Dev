using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IPatientVitalService
{
    Task<int> AddVitalAsync(VitalEntryViewModel model, int recordedByUserId);
    Task UpdateVitalAsync(VitalEntryViewModel model, int updatedByUserId);
    Task<(List<VitalHistoryRow> Rows, int TotalCount)> GetHistoryAsync(int patientId, int page, int pageSize);
    Task<PatientVital?> GetLatestAsync(int patientId);
    Task<PatientVital?> GetByIdAsync(int vitalId);
    Task DeleteAsync(int vitalId, int deletedByUserId);
}
