using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public interface IDistrictService
{
    Task<IEnumerable<DistrictMaster>> GetAllAsync();
    Task<DistrictMaster?> GetByIdAsync(int id);
    Task<IEnumerable<DistrictMaster>> GetByStateAsync(int stateId);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(DistrictMaster model, int? userId);
    Task UpdateAsync(DistrictMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
