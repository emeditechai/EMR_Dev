using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IInsuranceTPAApiClient
{
    Task<IEnumerable<InsuranceTPAListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTPAListItemViewModel?> GetByIdAsync(int id);

    Task<int> CreateAsync(InsuranceTPAFormViewModel model, int? userId = null);

    Task<bool> UpdateAsync(int id, InsuranceTPAFormViewModel model, int? userId = null);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
