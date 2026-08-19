using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IFloorService
{
    Task<IEnumerable<FloorMaster>> GetAllAsync(int? buildingId = null);
    Task<FloorMaster?> GetByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? buildingId = null, int? excludeId = null);
    Task<int> CreateAsync(FloorMaster m, int? userId);
    Task UpdateAsync(FloorMaster m, int? userId);
}
