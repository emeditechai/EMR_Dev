using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IPatientApiClient
{
    Task<PagedResult<PatientListItem>> GetByBranchAsync(
        int? branchId, int page = 1, int pageSize = 20, string? search = null, int? companyId = null);
    Task<PatientStats?> GetStatsAsync(int? branchId, int? companyId = null);

    Task<PatientDetail?> GetByIdAsync(int patientId, int? companyId = null);
    Task<int?>           CreateAsync(PatientCreateRequest request);
    Task<bool>           UpdateAsync(PatientUpdateRequest request);
    Task<OpdDashboardData?> GetOpdDashboardAsync(int branchId, string date, int? companyId = null);

    /// <summary>Patient Portal: saves a new login (password hash) for the patient; null when no active patient.</summary>
    Task<PatientPortalLoginTarget?> SetPortalLoginAsync(int patientId, string passwordHash, string salt, int? companyId = null);
}

