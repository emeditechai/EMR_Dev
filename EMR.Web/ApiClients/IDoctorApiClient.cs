using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IDoctorApiClient
{
    Task<PagedResult<DoctorListItem>> GetListAsync(int? branchId = null, string? searchQuery = null, int pageNumber = 1, int pageSize = 10);
    Task<DoctorDetail?>        GetByIdAsync(int doctorId, int? branchId = null);
    Task<int?>                 CreateAsync(DoctorCreateRequest request);
    Task<bool>                 UpdateAsync(DoctorUpdateRequest request);
    Task<DoctorListItem?>      GetLinkedDoctorAsync(int userId, string? email, string? displayName);
}
