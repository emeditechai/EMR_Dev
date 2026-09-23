using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabDescriptiveTestTemplateApiClient
{
    Task<IEnumerable<LabDescriptiveTestTemplateModel>> GetListAsync(bool? status = null, string? search = null, int? testId = null, int? companyId = null);
    Task<LabDescriptiveTestTemplateModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabDescriptiveTestTemplateCreateRequestModel req);
    Task<List<int>> BatchCreateAsync(LabDescriptiveTestTemplateBatchCreateRequestModel req);
    Task<bool> UpdateAsync(LabDescriptiveTestTemplateUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabDescriptiveTestTemplateToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<RadiologyTestItemModel>> GetRadiologyTestsAsync(int? companyId = null, string? search = null);
}
