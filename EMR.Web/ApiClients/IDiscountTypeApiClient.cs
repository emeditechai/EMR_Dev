using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IDiscountTypeApiClient
{
    Task<IEnumerable<DiscountTypeListItemViewModel>> GetListAsync(int? branchId = null, bool? status = null, string? search = null, int? companyId = null);
    Task<DiscountTypeFormViewModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(DiscountTypeFormViewModel model, int userId, int? companyId, int? branchId);
    Task UpdateAsync(DiscountTypeFormViewModel model, int userId, int? companyId, int? branchId);
    Task DeleteAsync(int id);
}
