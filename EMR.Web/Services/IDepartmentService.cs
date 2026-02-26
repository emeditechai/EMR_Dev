using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IDepartmentService
{
    Task<IEnumerable<DepartmentMaster>> GetAllAsync();
    Task<DepartmentMaster?> GetByIdAsync(int id);
    Task<IEnumerable<DepartmentMaster>> GetActiveAsync();
    Task<bool> CodeExistsAsync(string code, int? excludeId = null);
    Task<int> CreateAsync(DepartmentMaster m, int? userId);
    Task UpdateAsync(DepartmentMaster m, int? userId);
}
