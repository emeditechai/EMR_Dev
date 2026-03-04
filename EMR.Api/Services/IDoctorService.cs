using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorService
{
    Task<IEnumerable<DoctorListItem>>  GetListAsync(int? branchId);
    Task<DoctorDetail?>                GetByIdAsync(int doctorId, int? branchId = null);
    Task<int>                          CreateAsync(DoctorCreateRequest request);
    Task<bool>                         UpdateAsync(DoctorUpdateRequest request);
}
