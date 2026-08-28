using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabRateCardService
{
    Task<IEnumerable<LabRateCardHeaderModel>> GetListAsync(string? rateType, int? branchId, bool? status, int? companyId);
    Task<LabRateCardFullModel?> GetByIdAsync(int id);
    Task<int> SaveAsync(LabRateCardSaveRequest req);
    Task ToggleStatusAsync(LabRateCardToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
    Task<IEnumerable<LabItemModel>> GetAllItemsAsync(int companyId);
}
