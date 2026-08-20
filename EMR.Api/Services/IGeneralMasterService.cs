using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IGeneralMasterService
{
    Task<IEnumerable<ReferralDoctorListItem>> GetReferralDoctorsAsync();
    Task<IEnumerable<DoctorSpecialityListItem>> GetDoctorSpecialitiesAsync();
    Task<IEnumerable<DoctorSubSpecialityListItem>> GetDoctorSubSpecialitiesAsync(int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<IEnumerable<DepartmentListItem>> GetDepartmentsAsync();
    Task<IEnumerable<ClinicalUnitListItem>> GetClinicalUnitsAsync(int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<IEnumerable<BuildingListItem>> GetBuildingsAsync(int? companyId = null, int? branchId = null);
    Task<IEnumerable<FloorListItem>> GetFloorsAsync(int? buildingId = null);
    Task<IEnumerable<CountryListItem>> GetCountriesAsync();
    Task<IEnumerable<StateListItem>> GetStatesAsync(int? countryId = null);
    Task<IEnumerable<DistrictListItem>> GetDistrictsAsync(int? countryId = null, int? stateId = null);
    Task<IEnumerable<CityListItem>> GetCitiesAsync(int? countryId = null, int? stateId = null, int? districtId = null);
    Task<IEnumerable<AreaListItem>> GetAreasAsync(int? countryId = null, int? stateId = null, int? districtId = null, int? cityId = null);
}
