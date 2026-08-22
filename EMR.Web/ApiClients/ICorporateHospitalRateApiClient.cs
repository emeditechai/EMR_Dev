using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface ICorporateHospitalRateApiClient
{
    Task<IEnumerable<CorporateHospitalRateListItemViewModel>> GetListAsync(
        int? corporateId = null,
        int? branchId = null,
        string? rateServiceType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<CorporateHospitalRateListItemViewModel?> GetByIdAsync(int id);

    Task<int> CreateAsync(CorporateHospitalRateFormViewModel model, int? userId = null);

    Task<bool> UpdateAsync(int id, CorporateHospitalRateFormViewModel model, int? userId = null);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);

    Task<IEnumerable<MasterServiceItemViewModel>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null);
}
