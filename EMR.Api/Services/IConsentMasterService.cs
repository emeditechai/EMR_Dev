using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IConsentMasterService
{
    Task<IEnumerable<ConsentMasterListItemDto>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? consentType = null,
        string? language = null,
        int? procedureId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<ConsentMasterDetailDto?> GetByIdAsync(int id);
    Task<int> CreateAsync(ConsentMasterSaveRequest request);
    Task<bool> UpdateAsync(ConsentMasterSaveRequest request);
    Task<bool> ToggleStatusAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<ConsentProcedureOptionDto>> GetProcedureOptionsAsync(int? branchId = null);
}
