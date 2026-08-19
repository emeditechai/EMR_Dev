using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IPatientService
{
    Task<PagedResult<PatientListItem>>  GetByBranchAsync(int? companyId, int? branchId, int page, int pageSize, string? search = null);
    Task<PatientDetail?>                GetByIdAsync(int patientId, int? companyId = null);
    Task<int>                           CreateAsync(PatientCreateRequest request);
    Task<bool>                          UpdateAsync(PatientUpdateRequest request);
    Task<OpdDashboardData?>             GetOpdDashboardAsync(int? companyId, int branchId, DateTime date);
}

