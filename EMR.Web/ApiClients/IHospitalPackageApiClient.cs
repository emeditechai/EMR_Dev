using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IHospitalPackageApiClient
{
    Task<IEnumerable<HospitalPackageItemViewModel>> GetListAsync(int? branchId = null, string? packageType = null, bool? status = null, string? search = null, int? companyId = null);
    Task<HospitalPackageSaveViewModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(HospitalPackageSaveViewModel model, int userId);
    Task<bool> UpdateAsync(int id, HospitalPackageSaveViewModel model, int userId);
    Task<bool> ToggleStatusAsync(int id, int userId);
    Task<bool> DeleteAsync(int id, int userId);
    Task<IEnumerable<MasterLookupItemViewModel>> GetMasterLookupsAsync(int? branchId = null, int? companyId = null);
}
