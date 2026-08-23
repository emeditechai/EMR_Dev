using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IAnalyzerApiClient
{
    Task<List<AnalyzerListItem>> GetListAsync(
        int? branchId = null,
        int? departmentId = null,
        string? interfaceProtocol = null,
        bool? status = null,
        string? search = null);

    Task<AnalyzerDetail?> GetByIdAsync(int id);
    Task<int> CreateAsync(AnalyzerSaveRequest request);
    Task<bool> UpdateAsync(AnalyzerSaveRequest request);
    Task<bool> ToggleStatusAsync(int id, int? userId = null);
    Task<bool> DeleteAsync(int id);
}
