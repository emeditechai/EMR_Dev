using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IDoctorApiClient
{
    Task<List<DoctorListItem>> GetListAsync(int? branchId = null);
    Task<DoctorDetail?>        GetByIdAsync(int doctorId, int? branchId = null);
    Task<int?>                 CreateAsync(DoctorCreateRequest request);
    Task<bool>                 UpdateAsync(DoctorUpdateRequest request);
}
