using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IDoctorSpecialityService
{
    Task<IEnumerable<DoctorSpecialityMaster>> GetAllAsync();
    Task<DoctorSpecialityMaster?> GetByIdAsync(int id);
    Task<IEnumerable<DoctorSpecialityMaster>> GetActiveAsync();
    Task<bool> NameExistsAsync(string name, int? excludeId = null);
    Task<int> CreateAsync(DoctorSpecialityMaster model, int? userId);
    Task UpdateAsync(DoctorSpecialityMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
}
