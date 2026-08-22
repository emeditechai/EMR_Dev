using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IInsuranceTariffService
{
    Task<IEnumerable<InsuranceTariffListItemDto>> GetListAsync(
        int? insuranceTpaId = null,
        int? branchId = null,
        string? entitlementType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTariffDetailDto?> GetByIdAsync(int id);

    Task<int> CreateAsync(InsuranceTariffSaveRequest request);

    Task<bool> UpdateAsync(int id, InsuranceTariffSaveRequest request);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);

    Task<IEnumerable<InsuranceMasterServiceItemDto>> GetMasterItemsAsync(string? entitlementType = null, int? branchId = null, int? companyId = null);
}
