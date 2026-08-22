using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IGovernmentSchemeService
{
    Task<IEnumerable<GovernmentSchemeListItemDto>> GetListAsync(
        int? branchId = null,
        string? schemeType = null,
        bool? isActive = null,
        string? search = null,
        int? companyId = null);

    Task<GovernmentSchemeDetailDto?> GetByIdAsync(int id);

    Task<int> CreateAsync(GovernmentSchemeSaveRequest request);

    Task<bool> UpdateAsync(int id, GovernmentSchemeSaveRequest request);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
