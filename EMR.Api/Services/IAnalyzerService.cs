using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IAnalyzerService
{
    Task<IEnumerable<AnalyzerListItemDto>> GetListAsync(int? departmentId = null,
        string? interfaceProtocol = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<AnalyzerDetailDto?> GetByIdAsync(int id);
    Task<int> CreateAsync(AnalyzerSaveRequest request);
    Task<bool> UpdateAsync(AnalyzerSaveRequest request);
    Task<bool?> ToggleStatusAsync(int id, int? userId = null);
    Task<bool> DeleteAsync(int id);
}
