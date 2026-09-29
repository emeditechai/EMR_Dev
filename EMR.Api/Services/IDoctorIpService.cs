using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorIpService
{
    Task<IEnumerable<DoctorIpListItem>> GetListAsync(int? companyId, int? branchId, bool? status, string? search);
    Task<DoctorIpDetail?> GetByIdAsync(int id);
    Task<int> SaveAsync(DoctorIpSaveRequest req);
    Task ToggleStatusAsync(DoctorIpToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);

    Task<IEnumerable<DoctorIpSpeciality>> GetSpecialitiesAsync(int? companyId);
    Task<IEnumerable<DoctorIpLookupItem>> GetDoctorsAsync(int specialityId, int? companyId);
    Task<IEnumerable<DoctorIpItem>> GetItemsAsync(int? companyId);

    Task<DoctorIpAccessStatus> GetAccessStatusAsync(int companyId, int userId);
    Task<DoctorIpVerifyCodeResult> VerifyAccessCodeAsync(DoctorIpVerifyCodeRequest req);
    Task SetAccessCodeAsync(DoctorIpSetCodeRequest req);
}
