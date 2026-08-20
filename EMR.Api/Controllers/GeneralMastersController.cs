using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/general-masters")]
[Produces("application/json")]
public class GeneralMastersController(IGeneralMasterService masterService) : ControllerBase
{
    [HttpGet("referral-doctors")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ReferralDoctorListItem>>), 200)]
    public async Task<IActionResult> GetReferralDoctors()
    {
        var result = await masterService.GetReferralDoctorsAsync();
        return Ok(ApiResponse<IEnumerable<ReferralDoctorListItem>>.Ok(result));
    }

    [HttpGet("doctor-specialities")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorSpecialityListItem>>), 200)]
    public async Task<IActionResult> GetDoctorSpecialities()
    {
        var result = await masterService.GetDoctorSpecialitiesAsync();
        return Ok(ApiResponse<IEnumerable<DoctorSpecialityListItem>>.Ok(result));
    }

    [HttpGet("doctor-sub-specialities")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DoctorSubSpecialityListItem>>), 200)]
    public async Task<IActionResult> GetDoctorSubSpecialities(
        [FromQuery] int? specialityId, [FromQuery] int? companyId, [FromQuery] int? branchId)
    {
        var result = await masterService.GetDoctorSubSpecialitiesAsync(specialityId, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<DoctorSubSpecialityListItem>>.Ok(result));
    }

    [HttpGet("departments")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DepartmentListItem>>), 200)]
    public async Task<IActionResult> GetDepartments()
    {
        var result = await masterService.GetDepartmentsAsync();
        return Ok(ApiResponse<IEnumerable<DepartmentListItem>>.Ok(result));
    }

    [HttpGet("clinical-units")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ClinicalUnitListItem>>), 200)]
    public async Task<IActionResult> GetClinicalUnits(
        [FromQuery] int? departmentId, [FromQuery] int? specialityId, [FromQuery] int? companyId, [FromQuery] int? branchId)
    {
        var result = await masterService.GetClinicalUnitsAsync(departmentId, specialityId, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<ClinicalUnitListItem>>.Ok(result));
    }

    [HttpGet("buildings")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<BuildingListItem>>), 200)]
    public async Task<IActionResult> GetBuildings([FromQuery] int? companyId, [FromQuery] int? branchId)
    {
        var result = await masterService.GetBuildingsAsync(companyId, branchId);
        return Ok(ApiResponse<IEnumerable<BuildingListItem>>.Ok(result));
    }

    [HttpGet("floors")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<FloorListItem>>), 200)]
    public async Task<IActionResult> GetFloors([FromQuery] int? buildingId)
    {
        var result = await masterService.GetFloorsAsync(buildingId);
        return Ok(ApiResponse<IEnumerable<FloorListItem>>.Ok(result));
    }

    [HttpGet("countries")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<CountryListItem>>), 200)]
    public async Task<IActionResult> GetCountries()
    {
        var result = await masterService.GetCountriesAsync();
        return Ok(ApiResponse<IEnumerable<CountryListItem>>.Ok(result));
    }

    [HttpGet("states")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<StateListItem>>), 200)]
    public async Task<IActionResult> GetStates([FromQuery] int? countryId)
    {
        var result = await masterService.GetStatesAsync(countryId);
        return Ok(ApiResponse<IEnumerable<StateListItem>>.Ok(result));
    }

    [HttpGet("districts")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<DistrictListItem>>), 200)]
    public async Task<IActionResult> GetDistricts([FromQuery] int? countryId, [FromQuery] int? stateId)
    {
        var result = await masterService.GetDistrictsAsync(countryId, stateId);
        return Ok(ApiResponse<IEnumerable<DistrictListItem>>.Ok(result));
    }

    [HttpGet("cities")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<CityListItem>>), 200)]
    public async Task<IActionResult> GetCities([FromQuery] int? countryId, [FromQuery] int? stateId, [FromQuery] int? districtId)
    {
        var result = await masterService.GetCitiesAsync(countryId, stateId, districtId);
        return Ok(ApiResponse<IEnumerable<CityListItem>>.Ok(result));
    }

    [HttpGet("areas")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<AreaListItem>>), 200)]
    public async Task<IActionResult> GetAreas(
        [FromQuery] int? countryId, [FromQuery] int? stateId, [FromQuery] int? districtId, [FromQuery] int? cityId)
    {
        var result = await masterService.GetAreasAsync(countryId, stateId, districtId, cityId);
        return Ok(ApiResponse<IEnumerable<AreaListItem>>.Ok(result));
    }
}
