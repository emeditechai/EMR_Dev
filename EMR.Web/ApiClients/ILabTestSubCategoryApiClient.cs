using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabTestSubCategoryApiClient
{
    Task<IEnumerable<LabTestSubCategoryModel>> GetListAsync(int? branchId = null, int? categoryId = null, bool? status = null, string? search = null, int? companyId = null);
    Task<LabTestSubCategoryModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabTestSubCategoryCreateRequestModel req);
    Task<bool> UpdateAsync(LabTestSubCategoryUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabTestSubCategoryToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
}
