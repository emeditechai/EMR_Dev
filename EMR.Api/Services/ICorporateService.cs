using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ICorporateService
{
    Task<IEnumerable<CorporateListItemDto>> GetListAsync(int? branchId = null, string? corporateType = null, bool? status = null, string? search = null, int? companyId = null);
    Task<CorporateDetailDto?> GetByIdAsync(int id);
    Task<int> CreateAsync(CorporateSaveRequest request);
    Task<bool> UpdateAsync(int id, CorporateSaveRequest request);
    Task<bool> ToggleStatusAsync(int id, int? userId = null);
    Task<bool> DeleteAsync(int id, int? userId = null);
}
