using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabTestCategoryApiClient
{
    Task<IEnumerable<LabTestCategoryModel>> GetListAsync(int? departmentId = null, bool? status = null, string? search = null, int? companyId = null);

    /// <summary>Active categories of the given departments (CSV of department ids).</summary>
    Task<IEnumerable<LabTestCategoryOptionModel>> GetByDepartmentsAsync(string? departmentIds, int? companyId = null);
    Task<LabTestCategoryModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestCategoryCreateRequestModel req);
    Task<bool> UpdateAsync(LabTestCategoryUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabTestCategoryToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
