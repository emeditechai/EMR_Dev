using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IServiceService
{
    Task<IEnumerable<ServiceMaster>> GetAllByBranchAsync(int branchId);
    Task<ServiceMaster?> GetByIdAsync(int id, int branchId);
    Task<bool> ItemCodeExistsAsync(string itemCode, int branchId, int? excludeId = null);
    Task<int> CreateAsync(ServiceMaster m, int? userId);
    Task UpdateAsync(ServiceMaster m, int? userId);
}
