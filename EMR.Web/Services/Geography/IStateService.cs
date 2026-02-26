using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public interface IStateService
{
    Task<IEnumerable<StateMaster>> GetAllAsync();
    Task<StateMaster?> GetByIdAsync(int id);
    Task<IEnumerable<StateMaster>> GetByCountryAsync(int countryId);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(StateMaster model, int? userId);
    Task UpdateAsync(StateMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
