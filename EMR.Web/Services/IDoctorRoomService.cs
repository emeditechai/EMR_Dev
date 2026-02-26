using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public interface IDoctorRoomService
{
    Task<IEnumerable<DoctorRoomMaster>> GetAllByBranchAsync(int branchId);
    Task<DoctorRoomMaster?> GetByIdAsync(int id, int branchId);
    Task<bool> NameExistsAsync(string roomName, int branchId, int floorId, int? excludeId = null);
    Task<int> CreateAsync(DoctorRoomMaster m, int? userId);
    Task UpdateAsync(DoctorRoomMaster m, int? userId);
}
