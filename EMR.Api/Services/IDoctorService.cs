using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorService
{
    Task<PagedResult<DoctorListItem>>  GetListAsync(int? companyId, int? branchId, string? searchQuery = null, int pageNumber = 1, int pageSize = 10);
    Task<DoctorDetail?>                GetByIdAsync(int doctorId, int? branchId = null, int? companyId = null);
    Task<int>                          CreateAsync(DoctorCreateRequest request);
    Task<bool>                         UpdateAsync(DoctorUpdateRequest request);
    
    Task<DoctorListItem?>              GetLinkedDoctorAsync(int userId, string? email, string? displayName);
}

