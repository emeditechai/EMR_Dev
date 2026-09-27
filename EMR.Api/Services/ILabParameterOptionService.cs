using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabParameterOptionService
{
    Task<IEnumerable<LabParameterOptionListItem>> GetListAsync(bool? status, string? search, int? companyId, int? test_ID);
    Task<LabParameterOptionListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabParameterOptionCreateRequest req);
    Task UpdateAsync(LabParameterOptionUpdateRequest req);
    Task ToggleStatusAsync(LabParameterOptionToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabParameterOptionLookupItem>> LookupTestsAsync(int? companyId);
}
