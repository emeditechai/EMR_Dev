using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IInsuranceTariffService
{
    Task<IEnumerable<InsuranceTariffListItemViewModel>> GetListAsync(
        int? insuranceTpaId = null,
        int? branchId = null,
        string? entitlementType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTariffListItemViewModel?> GetByIdAsync(int id);

    Task<IEnumerable<InsuranceMasterServiceItemViewModel>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null);
}
