using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IHospitalPackageService
{
    Task<IEnumerable<HospitalPackageListItemDto>> GetListAsync(int? branchId, string? packageType, bool? status, string? search, int? companyId);
    Task<HospitalPackageHeaderDto?> GetByIdAsync(int id);
    Task<int> CreateAsync(HospitalPackageSaveRequest request);
    Task<bool> UpdateAsync(int id, HospitalPackageSaveRequest request);
    Task<bool> ToggleStatusAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<IEnumerable<MasterLookupItemDto>> GetMasterLookupsAsync(int? branchId, int? companyId);
}
