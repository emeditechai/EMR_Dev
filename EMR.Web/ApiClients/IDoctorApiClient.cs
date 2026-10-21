using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IDoctorApiClient
{
    Task<PagedResult<DoctorListItem>> GetListAsync(int? branchId = null, string? searchQuery = null, int pageNumber = 1, int pageSize = 10, int? companyId = null);
    /// <summary>Doctor Master list, paged and filtered on the server (SQLScripts/2315).</summary>
    Task<DoctorPagedList> GetPagedListAsync(int? companyId, int? branchId, string? search, string? status, string? referral,
        string? speciality, string? department, int? doctorId, int pageNumber, int pageSize);
    Task<DoctorDetail?>        GetByIdAsync(int doctorId, int? branchId = null, int? companyId = null);
    Task<int?>                 CreateAsync(DoctorCreateRequest request);
    Task<bool>                 UpdateAsync(DoctorUpdateRequest request);
    Task<DoctorListItem?>      GetLinkedDoctorAsync(int userId, string? email, string? displayName);
}

