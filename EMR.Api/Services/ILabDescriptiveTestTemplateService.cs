using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabDescriptiveTestTemplateService
{
    Task<IEnumerable<LabDescriptiveTestTemplateListItem>> GetListAsync(bool? status, string? search, int? testId, int? companyId);
    Task<LabDescriptiveTestTemplateListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabDescriptiveTestTemplateCreateRequest req);
    Task<List<int>> BatchCreateAsync(LabDescriptiveTestTemplateBatchCreateRequest req);
    Task UpdateAsync(LabDescriptiveTestTemplateUpdateRequest req);
    Task ToggleStatusAsync(LabDescriptiveTestTemplateToggleStatusRequest req);
    Task DeleteAsync(int id);
    Task<IEnumerable<LabDescriptiveTestTemplateListItem>> GetByTestIdAsync(int testId);
    Task BatchUpdateAsync(LabDescriptiveTestTemplateBatchUpdateRequest req);
    Task<IEnumerable<LabDescriptiveTestTemplateGroupedItem>> GetGroupedListAsync(bool? status, string? search, int? companyId);
    Task<IEnumerable<RadiologyTestItem>> GetRadiologyTestsAsync(int? companyId, string? search);
}
