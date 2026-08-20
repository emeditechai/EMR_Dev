using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IOpdMasterApiClient
{
    Task<IEnumerable<ServiceMaster>> GetServicesAsync(int branchId);
    Task<IEnumerable<DoctorRoomMaster>> GetDoctorRoomsAsync(int branchId);
    Task<IEnumerable<RoomDoctorAssignmentViewModel>> GetRoomDoctorAssignmentsAsync(int branchId);
    Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId);
    Task<IEnumerable<EmrInvestigationMaster>> GetEmrInvestigationsAsync(string? search = null);
    Task<IEnumerable<EmrMedicationMaster>> GetEmrMedicationsAsync(string? search = null);
}
