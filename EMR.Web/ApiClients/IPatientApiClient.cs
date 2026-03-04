using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IPatientApiClient
{
    Task<PagedResult<PatientListItem>> GetByBranchAsync(
        int? branchId, int page = 1, int pageSize = 20, string? search = null);

    Task<PatientDetail?> GetByIdAsync(int patientId);
    Task<int?>           CreateAsync(PatientCreateRequest request);
    Task<bool>           UpdateAsync(PatientUpdateRequest request);
}
