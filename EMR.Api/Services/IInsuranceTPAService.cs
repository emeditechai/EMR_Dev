using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IInsuranceTPAService
{
    Task<IEnumerable<InsuranceTPAListItemDto>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTPADetailDto?> GetByIdAsync(int id);

    Task<int> CreateAsync(InsuranceTPASaveRequest request);

    Task<bool> UpdateAsync(int id, InsuranceTPASaveRequest request);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);
}
