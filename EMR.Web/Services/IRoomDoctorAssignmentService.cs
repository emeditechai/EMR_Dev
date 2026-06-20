using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IRoomDoctorAssignmentService
{
    Task<IEnumerable<RoomDoctorAssignmentViewModel>> GetRoomAssignmentsAsync(int branchId);
    Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId);
    Task AssignDoctorAsync(int roomId, int doctorId, int? userId);
}
