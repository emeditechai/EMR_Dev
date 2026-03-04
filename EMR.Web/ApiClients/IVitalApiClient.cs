using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IVitalApiClient
{
    Task<VitalHistoryResult> GetHistoryAsync(int patientId, int page = 1, int pageSize = 10);
    Task<VitalRow?>          GetByIdAsync(int vitalId);
    Task<VitalRow?>          GetLatestAsync(int patientId);
    Task<VitalPrintData?>    GetPrintDataAsync(int patientId, int? branchId = null);
    Task<int?>               CreateAsync(VitalCreateRequest request);
    Task<bool>               UpdateAsync(VitalUpdateRequest request);
    Task<bool>               DeleteAsync(int vitalId, int deletedByUserId);
}
