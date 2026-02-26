using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IFloorService
{
    Task<IEnumerable<FloorMaster>> GetAllAsync();
    Task<FloorMaster?> GetByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(FloorMaster m, int? userId);
    Task UpdateAsync(FloorMaster m, int? userId);
}
