using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IGovernmentSchemeService
{
    Task<IEnumerable<GovernmentSchemeListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? schemeType = null,
        bool? isActive = null,
        string? search = null,
        int? companyId = null);

    Task<GovernmentSchemeListItemViewModel?> GetByIdAsync(int id);
}
