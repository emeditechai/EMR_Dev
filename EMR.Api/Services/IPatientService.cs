using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IPatientService
{
    Task<PagedResult<PatientListItem>>  GetByBranchAsync(int? branchId, int page, int pageSize, string? search = null);
    Task<PatientDetail?>                GetByIdAsync(int patientId);
    Task<int>                           CreateAsync(PatientCreateRequest request);
    Task<bool>                          UpdateAsync(PatientUpdateRequest request);
}
