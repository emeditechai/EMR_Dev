using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public interface ICityService
{
    Task<IEnumerable<CityMaster>> GetAllAsync();
    Task<CityMaster?> GetByIdAsync(int id);
    Task<IEnumerable<CityMaster>> GetByDistrictAsync(int districtId);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(CityMaster model, int? userId);
    Task UpdateAsync(CityMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
