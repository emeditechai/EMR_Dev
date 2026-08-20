using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class GeneralMasterApiClient(IHttpClientFactory factory) : IGeneralMasterApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<ReferralDoctorMaster>> GetReferralDoctorsAsync()
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ReferralDoctorMaster>>>("api/general-masters/referral-doctors");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorSpecialityMaster>> GetDoctorSpecialitiesAsync()
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorSpecialityMaster>>>("api/general-masters/doctor-specialities");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<DoctorSubSpecialityListItemViewModel>> GetDoctorSubSpecialitiesAsync(
        int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (specialityId.HasValue) queryParams.Add($"specialityId={specialityId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/general-masters/doctor-sub-specialities" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorSubSpecialityListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<DepartmentMaster>> GetDepartmentsAsync()
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<DepartmentMaster>>>("api/general-masters/departments");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<ClinicalUnitListItemViewModel>> GetClinicalUnitsAsync(
        int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (departmentId.HasValue) queryParams.Add($"departmentId={departmentId.Value}");
        if (specialityId.HasValue) queryParams.Add($"specialityId={specialityId.Value}");
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/general-masters/clinical-units" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ClinicalUnitListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<BuildingListItemViewModel>> GetBuildingsAsync(int? companyId = null, int? branchId = null)
    {
        var queryParams = new List<string>();
        if (companyId.HasValue && companyId.Value > 0) queryParams.Add($"companyId={companyId.Value}");
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");

        var url = "api/general-masters/buildings" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<BuildingListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<FloorMaster>> GetFloorsAsync(int? buildingId = null)
    {
        var queryParams = new List<string>();
        if (buildingId.HasValue) queryParams.Add($"buildingId={buildingId.Value}");

        var url = "api/general-masters/floors" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<FloorMaster>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<CountryMaster>> GetCountriesAsync()
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<List<CountryMaster>>>("api/general-masters/countries");
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<StateMaster>> GetStatesAsync(int? countryId = null)
    {
        var queryParams = new List<string>();
        if (countryId.HasValue) queryParams.Add($"countryId={countryId.Value}");

        var url = "api/general-masters/states" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<StateMaster>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<DistrictMaster>> GetDistrictsAsync(int? countryId = null, int? stateId = null)
    {
        var queryParams = new List<string>();
        if (countryId.HasValue) queryParams.Add($"countryId={countryId.Value}");
        if (stateId.HasValue) queryParams.Add($"stateId={stateId.Value}");

        var url = "api/general-masters/districts" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<DistrictMaster>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<CityMaster>> GetCitiesAsync(int? countryId = null, int? stateId = null, int? districtId = null)
    {
        var queryParams = new List<string>();
        if (countryId.HasValue) queryParams.Add($"countryId={countryId.Value}");
        if (stateId.HasValue) queryParams.Add($"stateId={stateId.Value}");
        if (districtId.HasValue) queryParams.Add($"districtId={districtId.Value}");

        var url = "api/general-masters/cities" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<CityMaster>>>(url);
        return response?.Data ?? [];
    }

    public async Task<IEnumerable<AreaMaster>> GetAreasAsync(int? countryId = null, int? stateId = null, int? districtId = null, int? cityId = null)
    {
        var queryParams = new List<string>();
        if (countryId.HasValue) queryParams.Add($"countryId={countryId.Value}");
        if (stateId.HasValue) queryParams.Add($"stateId={stateId.Value}");
        if (districtId.HasValue) queryParams.Add($"districtId={districtId.Value}");
        if (cityId.HasValue) queryParams.Add($"cityId={cityId.Value}");

        var url = "api/general-masters/areas" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : string.Empty);
        var response = await _http.GetFromJsonAsync<ApiResponse<List<AreaMaster>>>(url);
        return response?.Data ?? [];
    }
}
