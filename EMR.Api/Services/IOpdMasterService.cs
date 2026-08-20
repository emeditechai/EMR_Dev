using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IOpdMasterService
{
    Task<IEnumerable<ServiceListItem>> GetServicesAsync(int branchId);
    Task<IEnumerable<DoctorRoomListItem>> GetDoctorRoomsAsync(int branchId);
    Task<IEnumerable<RoomDoctorAssignmentListItem>> GetRoomDoctorAssignmentsAsync(int branchId);
    Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId);
    Task<IEnumerable<EmrInvestigationListItem>> GetEmrInvestigationsAsync(string? search = null);
    Task<IEnumerable<EmrMedicationListItem>> GetEmrMedicationsAsync(string? search = null);
}
