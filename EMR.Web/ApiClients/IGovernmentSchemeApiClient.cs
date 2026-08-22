using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IGovernmentSchemeApiClient
{
    Task<IEnumerable<GovernmentSchemeListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? schemeType = null,
        bool? isActive = null,
        string? search = null,
        int? companyId = null);

    Task<GovernmentSchemeListItemViewModel?> GetByIdAsync(int id);

    Task<int> CreateAsync(GovernmentSchemeFormViewModel model, int? userId = null);

    Task<bool> UpdateAsync(int id, GovernmentSchemeFormViewModel model, int? userId = null);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
