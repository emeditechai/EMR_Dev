using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class OpdMasterApiClient(IHttpClientFactory factory) : IOpdMasterApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<ServiceMaster>> GetServicesAsync(int branchId)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ServiceMaster>>>($"api/opd-masters/services?branchId={branchId}");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorRoomMaster>> GetDoctorRoomsAsync(int branchId)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorRoomMaster>>>($"api/opd-masters/doctor-rooms?branchId={branchId}");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<RoomDoctorAssignmentViewModel>> GetRoomDoctorAssignmentsAsync(int branchId)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<RoomDoctorAssignmentViewModel>>>($"api/opd-masters/room-doctor-assignments?branchId={branchId}");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<OPDDoctorOptionDto>>>($"api/opd-masters/opd-doctors?branchId={branchId}");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<EmrInvestigationMaster>> GetEmrInvestigationsAsync(string? search = null)
    {
        var url = "api/opd-masters/emr-investigations" + (!string.IsNullOrWhiteSpace(search) ? $"?search={Uri.EscapeDataString(search)}" : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<EmrInvestigationMaster>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<EmrMedicationMaster>> GetEmrMedicationsAsync(string? search = null)
    {
        var url = "api/opd-masters/emr-medications" + (!string.IsNullOrWhiteSpace(search) ? $"?search={Uri.EscapeDataString(search)}" : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<EmrMedicationMaster>>>(url);
        return response?.Data ?? [];
    }
}
