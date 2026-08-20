using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class GeneralMasterService(IDbConnectionFactory db) : IGeneralMasterService
{
    public async Task<IEnumerable<ReferralDoctorListItem>> GetReferralDoctorsAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ReferralDoctorListItem>(
            "usp_Api_ReferralDoctor_GetList",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorSpecialityListItem>> GetDoctorSpecialitiesAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorSpecialityListItem>(
            "usp_Api_DoctorSpeciality_GetList",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorSubSpecialityListItem>> GetDoctorSubSpecialitiesAsync(
        int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorSubSpecialityListItem>(
            "usp_Api_DoctorSubSpeciality_GetList",
            new { SpecialityId = specialityId, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DepartmentListItem>> GetDepartmentsAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DepartmentListItem>(
            "usp_Api_Department_GetList",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ClinicalUnitListItem>> GetClinicalUnitsAsync(
        int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ClinicalUnitListItem>(
            "usp_Api_ClinicalUnit_GetList",
            new { DepartmentId = departmentId, SpecialityId = specialityId, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<BuildingListItem>> GetBuildingsAsync(int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BuildingListItem>(
            "usp_Api_Building_GetList",
            new { CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<FloorListItem>> GetFloorsAsync(int? buildingId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<FloorListItem>(
            "usp_Api_Floor_GetList",
            new { BuildingId = buildingId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<CountryListItem>> GetCountriesAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CountryListItem>(
            "usp_Api_Country_GetList",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<StateListItem>> GetStatesAsync(int? countryId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<StateListItem, CountryListItem, StateListItem>(
            "usp_Api_State_GetList",
            (s, c) => { s.Country = c; s.CountryName = c.CountryName; return s; },
            new { CountryId = countryId },
            splitOn: "CountryId",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DistrictListItem>> GetDistrictsAsync(int? countryId = null, int? stateId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DistrictListItem, StateListItem, DistrictListItem>(
            "usp_Api_District_GetList",
            (d, s) => { d.State = s; d.StateName = s.StateName; return d; },
            new { CountryId = countryId, StateId = stateId },
            splitOn: "StateId",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<CityListItem>> GetCitiesAsync(int? countryId = null, int? stateId = null, int? districtId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CityListItem, DistrictListItem, CityListItem>(
            "usp_Api_City_GetList",
            (c, d) => { c.District = d; c.DistrictName = d.DistrictName; return c; },
            new { CountryId = countryId, StateId = stateId, DistrictId = districtId },
            splitOn: "DistrictId",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<AreaListItem>> GetAreasAsync(int? countryId = null, int? stateId = null, int? districtId = null, int? cityId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AreaListItem, CityListItem, AreaListItem>(
            "usp_Api_Area_GetList",
            (a, c) => { a.City = c; a.CityName = c.CityName; return a; },
            new { CountryId = countryId, StateId = stateId, DistrictId = districtId, CityId = cityId },
            splitOn: "CityId",
            commandType: CommandType.StoredProcedure);
    }
}
