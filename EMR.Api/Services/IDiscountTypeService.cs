using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDiscountTypeService
{
    Task<IEnumerable<DiscountTypeListItem>> GetListAsync(int? branchId = null, bool? status = null, string? search = null, int? companyId = null);
    Task<DiscountTypeDetail?> GetByIdAsync(int id);
    Task<int> CreateAsync(CreateDiscountTypeRequest request, int userId);
    Task UpdateAsync(UpdateDiscountTypeRequest request, int userId);
    Task DeleteAsync(int id);
}
