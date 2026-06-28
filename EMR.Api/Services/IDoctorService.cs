using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorService
{
    Task<IEnumerable<DoctorListItem>>  GetListAsync(int? branchId, string? searchQuery = null);
    Task<DoctorDetail?>                GetByIdAsync(int doctorId, int? branchId = null);
    Task<int>                          CreateAsync(DoctorCreateRequest request);
    Task<bool>                         UpdateAsync(DoctorUpdateRequest request);
    
    Task<DoctorListItem?>              GetLinkedDoctorAsync(int userId, string? email, string? displayName);
}
