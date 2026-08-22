using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IInsuranceTariffApiClient
{
    Task<IEnumerable<InsuranceTariffListItemViewModel>> GetListAsync(
        int? insuranceTpaId = null,
        int? branchId = null,
        string? entitlementType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTariffListItemViewModel?> GetByIdAsync(int id);

    Task<int> CreateAsync(InsuranceTariffFormViewModel model, int? userId = null);

    Task<bool> UpdateAsync(int id, InsuranceTariffFormViewModel model, int? userId = null);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);

    Task<IEnumerable<InsuranceMasterServiceItemViewModel>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null);
}
