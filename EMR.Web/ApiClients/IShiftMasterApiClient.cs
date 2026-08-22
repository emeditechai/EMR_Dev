using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IShiftMasterApiClient
{
    Task<IEnumerable<ShiftMasterListItemViewModel>> GetListAsync(
        int? branchId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<ShiftMasterListItemViewModel?> GetByIdAsync(int id);

    Task<int> CreateAsync(ShiftMasterFormViewModel model, int? userId = null);

    Task<bool> UpdateAsync(int id, ShiftMasterFormViewModel model, int? userId = null);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
