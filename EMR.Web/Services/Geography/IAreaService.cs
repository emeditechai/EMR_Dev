using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public interface IAreaService
{
    Task<IEnumerable<AreaMaster>> GetAllAsync();
    Task<AreaMaster?> GetByIdAsync(int id);
    Task<IEnumerable<AreaMaster>> GetByCityAsync(int cityId);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(AreaMaster model, int? userId);
    Task UpdateAsync(AreaMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
