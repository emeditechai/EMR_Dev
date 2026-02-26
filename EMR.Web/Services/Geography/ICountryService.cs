using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public interface ICountryService
{
    Task<IEnumerable<CountryMaster>> GetAllAsync();
    Task<CountryMaster?> GetByIdAsync(int id);
    Task<IEnumerable<CountryMaster>> GetActiveAsync();
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(CountryMaster model, int? userId);
    Task UpdateAsync(CountryMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
