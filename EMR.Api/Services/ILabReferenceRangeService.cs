using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabReferenceRangeService
{
    Task<IEnumerable<LabReferenceRangeListItem>> GetListAsync(int? testId, string? gender, bool? status, string? search, int? companyId);
    Task<LabReferenceRangeDetail?> GetByIdAsync(int id, int? companyId);
    Task<int> CreateAsync(LabReferenceRangeCreateRequest req);
    Task UpdateAsync(LabReferenceRangeUpdateRequest req);
    Task DeleteAsync(int id, int companyId, int? userId);
    Task<bool> ToggleStatusAsync(int id, int companyId, int? userId);
    Task<IEnumerable<LabNumericTestOption>> GetNumericTestsAsync(int companyId);
}
