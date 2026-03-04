using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IVitalService
{
    Task<int>                CreateAsync(VitalCreateRequest request);
    Task                     UpdateAsync(VitalUpdateRequest request);
    Task<VitalHistoryResult> GetHistoryAsync(int patientId, int page, int pageSize);
    Task<VitalRow?>          GetByIdAsync(int vitalId);
    Task<VitalRow?>          GetLatestAsync(int patientId);
    Task                     DeleteAsync(int vitalId, int deletedByUserId);
    Task<VitalPrintData?>    GetPrintDataAsync(int patientId, int? branchId);
}
