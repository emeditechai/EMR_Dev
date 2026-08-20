using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IGeneralMasterApiClient
{
    Task<IEnumerable<ReferralDoctorMaster>> GetReferralDoctorsAsync();
    Task<IEnumerable<DoctorSpecialityMaster>> GetDoctorSpecialitiesAsync();
    Task<IEnumerable<DoctorSubSpecialityListItemViewModel>> GetDoctorSubSpecialitiesAsync(int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<IEnumerable<DepartmentMaster>> GetDepartmentsAsync();
    Task<IEnumerable<ClinicalUnitListItemViewModel>> GetClinicalUnitsAsync(int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null);
    Task<IEnumerable<BuildingListItemViewModel>> GetBuildingsAsync(int? companyId = null, int? branchId = null);
    Task<IEnumerable<FloorMaster>> GetFloorsAsync(int? buildingId = null);
    Task<IEnumerable<CountryMaster>> GetCountriesAsync();
    Task<IEnumerable<StateMaster>> GetStatesAsync(int? countryId = null);
    Task<IEnumerable<DistrictMaster>> GetDistrictsAsync(int? countryId = null, int? stateId = null);
    Task<IEnumerable<CityMaster>> GetCitiesAsync(int? countryId = null, int? stateId = null, int? districtId = null);
    Task<IEnumerable<AreaMaster>> GetAreasAsync(int? countryId = null, int? stateId = null, int? districtId = null, int? cityId = null);
}
