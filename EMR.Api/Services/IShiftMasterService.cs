using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IShiftMasterService
{
    Task<IEnumerable<ShiftMasterListItemDto>> GetListAsync(
        int? branchId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<ShiftMasterDetailDto?> GetByIdAsync(int id);

    Task<int> CreateAsync(ShiftMasterSaveRequest request);

    Task<bool> UpdateAsync(int id, ShiftMasterSaveRequest request);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
