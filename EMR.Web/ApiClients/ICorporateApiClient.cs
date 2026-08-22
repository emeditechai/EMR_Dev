using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface ICorporateApiClient
{
    Task<IEnumerable<CorporateListItemViewModel>> GetListAsync(int? branchId = null, string? type = null, bool? status = null, string? search = null, int? companyId = null);
    Task<CorporateListItemViewModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(CorporateFormViewModel model, int? userId = null);
    Task<bool> UpdateAsync(int id, CorporateFormViewModel model, int? userId = null);
    Task<bool> ToggleStatusAsync(int id, int? userId = null);
    Task<bool> DeleteAsync(int id, int? userId = null);
}
