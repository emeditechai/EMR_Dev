using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class IpdMasterApiClient(IHttpClientFactory factory) : IIpdMasterApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    // ── 1. Wards ──────────────────────────────────────────────────────────────
    public async Task<IEnumerable<WardListItemViewModel>> GetWardsAsync(
        int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (floorId.HasValue) queryParams.Add($"floorId={floorId.Value}");
        if (departmentId.HasValue) queryParams.Add($"departmentId={departmentId.Value}");
        if (!string.IsNullOrWhiteSpace(wardType)) queryParams.Add($"wardType={Uri.EscapeDataString(wardType)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/wards" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<WardListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 2. Nursing Stations ───────────────────────────────────────────────────
    public async Task<IEnumerable<NursingStationListItemViewModel>> GetNursingStationsAsync(
        int? wardId = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (wardId.HasValue) queryParams.Add($"wardId={wardId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/nursing-stations" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<NursingStationListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 3. Rooms ──────────────────────────────────────────────────────────────
    public async Task<IEnumerable<RoomListItemViewModel>> GetRoomsAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (buildingId.HasValue) queryParams.Add($"buildingId={buildingId.Value}");
        if (floorId.HasValue) queryParams.Add($"floorId={floorId.Value}");
        if (wardId.HasValue) queryParams.Add($"wardId={wardId.Value}");
        if (!string.IsNullOrWhiteSpace(roomCategory)) queryParams.Add($"roomCategory={Uri.EscapeDataString(roomCategory)}");
        if (!string.IsNullOrWhiteSpace(roomType)) queryParams.Add($"roomType={Uri.EscapeDataString(roomType)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/rooms" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<RoomListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 4. Bed Categories ─────────────────────────────────────────────────────
    public async Task<IEnumerable<BedCategoryListItemViewModel>> GetBedCategoriesAsync(
        int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/bed-categories" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<BedCategoryListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 5. Beds ───────────────────────────────────────────────────────────────
    public async Task<IEnumerable<BedListItemViewModel>> GetBedsAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (buildingId.HasValue) queryParams.Add($"buildingId={buildingId.Value}");
        if (wardId.HasValue) queryParams.Add($"wardId={wardId.Value}");
        if (roomId.HasValue) queryParams.Add($"roomId={roomId.Value}");
        if (bedCategoryId.HasValue) queryParams.Add($"bedCategoryId={bedCategoryId.Value}");
        if (!string.IsNullOrWhiteSpace(bedStatus)) queryParams.Add($"bedStatus={Uri.EscapeDataString(bedStatus)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/beds" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<BedListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 6. Tariff Categories ──────────────────────────────────────────────────
    public async Task<IEnumerable<TariffCategoryListItemViewModel>> GetTariffCategoriesAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (!string.IsNullOrWhiteSpace(patientCategory)) queryParams.Add($"patientCategory={Uri.EscapeDataString(patientCategory)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/tariff-categories" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<TariffCategoryListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 7. Bed/Room Tariffs ───────────────────────────────────────────────────
    public async Task<IEnumerable<BedRoomTariffListItemViewModel>> GetBedRoomTariffsAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (wardId.HasValue) queryParams.Add($"wardId={wardId.Value}");
        if (roomId.HasValue) queryParams.Add($"roomId={roomId.Value}");
        if (bedCategoryId.HasValue) queryParams.Add($"bedCategoryId={bedCategoryId.Value}");
        if (tariffCategoryId.HasValue) queryParams.Add($"tariffCategoryId={tariffCategoryId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/ipd-masters/bedroom-tariffs" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<BedRoomTariffListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 8. Hospital Services ──────────────────────────────────────────────────
    public async Task<IEnumerable<HospitalServiceListItemViewModel>> GetHospitalServicesAsync(
        int? branchId = null, int? departmentId = null, string? serviceType = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (departmentId.HasValue) queryParams.Add($"departmentId={departmentId.Value}");
        if (!string.IsNullOrWhiteSpace(serviceType)) queryParams.Add($"serviceType={Uri.EscapeDataString(serviceType)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/hospital-services" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HospitalServiceListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 9. Hospital Service Rates ─────────────────────────────────────────────
    public async Task<IEnumerable<HospitalServiceRateListItemViewModel>> GetHospitalServiceRatesAsync(
        int? branchId = null, int? tariffCategoryId = null, int? hospitalServiceId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (tariffCategoryId.HasValue) queryParams.Add($"tariffCategoryId={tariffCategoryId.Value}");
        if (hospitalServiceId.HasValue) queryParams.Add($"hospitalServiceId={hospitalServiceId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/hospital-service-rates" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<HospitalServiceRateListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 10. Procedures ────────────────────────────────────────────────────────
    public async Task<IEnumerable<ProcedureListItemViewModel>> GetProceduresAsync(
        int? branchId = null, int? departmentId = null, int? specialityId = null, string? procedureCategory = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (departmentId.HasValue) queryParams.Add($"departmentId={departmentId.Value}");
        if (specialityId.HasValue) queryParams.Add($"specialityId={specialityId.Value}");
        if (!string.IsNullOrWhiteSpace(procedureCategory)) queryParams.Add($"procedureCategory={Uri.EscapeDataString(procedureCategory)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/procedures" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ProcedureListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 11. Procedure Tariffs ─────────────────────────────────────────────────
    public async Task<IEnumerable<ProcedureTariffListItemViewModel>> GetProcedureTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? procedureId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (tariffCategoryId.HasValue) queryParams.Add($"tariffCategoryId={tariffCategoryId.Value}");
        if (procedureId.HasValue) queryParams.Add($"procedureId={procedureId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/procedure-tariffs" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ProcedureTariffListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 12. OTs ───────────────────────────────────────────────────────────────
    public async Task<IEnumerable<OtListItemViewModel>> GetOtsAsync(
        int? branchId = null, int? floorId = null, string? otType = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (floorId.HasValue) queryParams.Add($"floorId={floorId.Value}");
        if (!string.IsNullOrWhiteSpace(otType)) queryParams.Add($"otType={Uri.EscapeDataString(otType)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/ots" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<OtListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 13. OT Equipments ─────────────────────────────────────────────────────
    public async Task<IEnumerable<OtEquipmentListItemViewModel>> GetOtEquipmentsAsync(
        int? branchId = null, int? otId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (otId.HasValue) queryParams.Add($"otId={otId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/ot-equipments" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<OtEquipmentListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 14. OT Tariffs ────────────────────────────────────────────────────────
    public async Task<IEnumerable<OtTariffListItemViewModel>> GetOtTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? otId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (tariffCategoryId.HasValue) queryParams.Add($"tariffCategoryId={tariffCategoryId.Value}");
        if (otId.HasValue) queryParams.Add($"otId={otId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/ot-tariffs" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<OtTariffListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 15. Anaesthesia Types ─────────────────────────────────────────────────
    public async Task<IEnumerable<AnaesthesiaTypeListItemViewModel>> GetAnaesthesiaTypesAsync(
        int? branchId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/anaesthesia-types" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<AnaesthesiaTypeListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 16. Anaesthesia Rates ─────────────────────────────────────────────────
    public async Task<IEnumerable<AnaesthesiaRateListItemViewModel>> GetAnaesthesiaRatesAsync(
        int? branchId = null, int? procedureId = null, int? anaesthesiaTypeId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (procedureId.HasValue) queryParams.Add($"procedureId={procedureId.Value}");
        if (anaesthesiaTypeId.HasValue) queryParams.Add($"anaesthesiaTypeId={anaesthesiaTypeId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/anaesthesia-rates" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<AnaesthesiaRateListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 17. ICU Configurations ────────────────────────────────────────────────
    public async Task<IEnumerable<IcuListItemViewModel>> GetIcusAsync(
        int? branchId = null, int? wardId = null, string? icuType = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (wardId.HasValue) queryParams.Add($"wardId={wardId.Value}");
        if (!string.IsNullOrWhiteSpace(icuType)) queryParams.Add($"icuType={Uri.EscapeDataString(icuType)}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/icus" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<IcuListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 18. ICU Tariffs ───────────────────────────────────────────────────────
    public async Task<IEnumerable<IcuTariffListItemViewModel>> GetIcuTariffsAsync(
        int? branchId = null, int? icuId = null, int? tariffCategoryId = null, int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (icuId.HasValue) queryParams.Add($"icuId={icuId.Value}");
        if (tariffCategoryId.HasValue) queryParams.Add($"tariffCategoryId={tariffCategoryId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/ipd-masters/icu-tariffs" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<IcuTariffListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    // ── 19. ICU Tariff Details ────────────────────────────────────────────────
    public async Task<IEnumerable<IcuTariffDetailFormViewModel>> GetIcuTariffDetailsAsync(int icuTariffId)
    {
        var url = $"api/ipd-masters/icu-tariffs/{icuTariffId}/details";
        var response = await _http.GetFromJsonAsync<ApiResponse<List<IcuTariffDetailFormViewModel>>>(url);
        return response?.Data ?? [];
    }
}





