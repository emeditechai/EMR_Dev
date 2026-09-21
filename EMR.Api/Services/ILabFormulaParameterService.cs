using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabFormulaParameterService
{
    Task<IEnumerable<LabFormulaParameterListItem>> GetListAsync(bool? status, string? search, int? companyId);
    Task<LabFormulaParameterListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabFormulaParameterCreateRequest req);
    Task UpdateAsync(LabFormulaParameterUpdateRequest req);
    Task ToggleStatusAsync(LabFormulaParameterToggleStatusRequest req);
    Task DeleteAsync(int id);
    Task<IEnumerable<NumericTestItem>> GetNumericTestsAsync(int? companyId, string? search);
}
