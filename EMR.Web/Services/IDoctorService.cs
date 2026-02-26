using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IDoctorService
{
    Task<IEnumerable<DoctorListItemViewModel>> GetListForBranchAsync(int? branchId);
    Task<DoctorMaster?> GetByIdAsync(int id);
    Task<DoctorDetailsViewModel?> GetDetailsAsync(int id, int? branchId);
    Task<List<int>> GetBranchIdsAsync(int doctorId);
    Task<List<int>> GetDepartmentIdsAsync(int doctorId);
    Task<bool> IsVisibleForBranchAsync(int doctorId, int? branchId);
    Task<int> CreateAsync(DoctorMaster doctor, IEnumerable<int> branchIds, IEnumerable<int> departmentIds, int? userId);
    Task UpdateAsync(DoctorMaster doctor, IEnumerable<int> branchIds, IEnumerable<int> departmentIds, int? userId);
}
