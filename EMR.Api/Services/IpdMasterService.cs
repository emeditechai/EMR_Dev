using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class IpdMasterService(IDbConnectionFactory db) : IIpdMasterService
{
    // ── 1. Ward Master ────────────────────────────────────────────────────────
    public async Task<IEnumerable<WardListItem>> GetWardsAsync(
        int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<WardListItem>(
            "usp_Api_Ward_GetList",
            new { FloorId = floorId, DepartmentId = departmentId, WardType = wardType, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 2. Nursing Station Master ─────────────────────────────────────────────
    public async Task<IEnumerable<NursingStationListItem>> GetNursingStationsAsync(
        int? wardId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<NursingStationListItem>(
            "usp_Api_NursingStation_GetList",
            new { WardId = wardId, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 3. IPD Room Master ───────────────────────────────────────────────────
    public async Task<IEnumerable<RoomListItem>> GetRoomsAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<RoomListItem>(
            "usp_Api_Room_GetList",
            new { BuildingId = buildingId, FloorId = floorId, WardId = wardId, RoomCategory = roomCategory, RoomType = roomType, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 4. Bed Category Master ────────────────────────────────────────────────
    public async Task<IEnumerable<BedCategoryListItem>> GetBedCategoriesAsync(
        int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BedCategoryListItem>(
            "usp_Api_BedCategory_GetList",
            new { CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 5. Bed Master ─────────────────────────────────────────────────────────
    public async Task<IEnumerable<BedListItem>> GetBedsAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BedListItem>(
            "usp_Api_Bed_GetList",
            new { BuildingId = buildingId, WardId = wardId, RoomId = roomId, BedCategoryId = bedCategoryId, BedStatus = bedStatus, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 6. Tariff Category Master ─────────────────────────────────────────────
    public async Task<IEnumerable<TariffCategoryListItem>> GetTariffCategoriesAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<TariffCategoryListItem>(
            "usp_Api_TariffCategory_GetList",
            new { PatientCategory = patientCategory, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 7. Bed/Room Tariff Master ─────────────────────────────────────────────
    public async Task<IEnumerable<BedRoomTariffListItem>> GetBedRoomTariffsAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BedRoomTariffListItem>(
            "usp_Api_BedRoomTariff_GetList",
            new { WardId = wardId, RoomId = roomId, BedCategoryId = bedCategoryId, TariffCategoryId = tariffCategoryId, CompanyId = companyId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 8. Hospital Service Master ────────────────────────────────────────────
    public async Task<IEnumerable<HospitalServiceListItem>> GetHospitalServicesAsync(
        int? branchId = null, int? departmentId = null, string? serviceType = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<HospitalServiceListItem>(
            "usp_Api_HospitalService_GetList",
            new { BranchId = branchId, DepartmentId = departmentId, ServiceType = serviceType, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 9. Hospital Service Rate Master ───────────────────────────────────────
    public async Task<IEnumerable<HospitalServiceRateListItem>> GetHospitalServiceRatesAsync(
        int? branchId = null, int? tariffCategoryId = null, int? hospitalServiceId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<HospitalServiceRateListItem>(
            "usp_Api_HospitalServiceRate_GetList",
            new { BranchId = branchId, TariffCategoryId = tariffCategoryId, HospitalServiceId = hospitalServiceId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 10. Procedure Master ──────────────────────────────────────────────────
    public async Task<IEnumerable<ProcedureListItem>> GetProceduresAsync(
        int? branchId = null, int? departmentId = null, int? specialityId = null, string? procedureCategory = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ProcedureListItem>(
            "usp_Api_Procedure_GetList",
            new { BranchId = branchId, DepartmentId = departmentId, SpecialityId = specialityId, ProcedureCategory = procedureCategory, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 11. Procedure Tariff Master ───────────────────────────────────────────
    public async Task<IEnumerable<ProcedureTariffListItem>> GetProcedureTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? procedureId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ProcedureTariffListItem>(
            "usp_Api_ProcedureTariff_GetList",
            new { BranchId = branchId, TariffCategoryId = tariffCategoryId, ProcedureId = procedureId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 12. OT Master ─────────────────────────────────────────────────────────
    public async Task<IEnumerable<OtListItem>> GetOtsAsync(
        int? branchId = null, int? floorId = null, string? otType = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OtListItem>(
            "usp_Api_Ot_GetList",
            new { BranchId = branchId, FloorId = floorId, OtType = otType, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 13. OT Equipment Master ───────────────────────────────────────────────
    public async Task<IEnumerable<OtEquipmentListItem>> GetOtEquipmentsAsync(
        int? branchId = null, int? otId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OtEquipmentListItem>(
            "usp_Api_OtEquipment_GetList",
            new { BranchId = branchId, OtId = otId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 14. OT Tariff Master ──────────────────────────────────────────────────
    public async Task<IEnumerable<OtTariffListItem>> GetOtTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? otId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OtTariffListItem>(
            "usp_Api_OtTariff_GetList",
            new { BranchId = branchId, TariffCategoryId = tariffCategoryId, OtId = otId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 15. Anaesthesia Type Master ───────────────────────────────────────────
    public async Task<IEnumerable<AnaesthesiaTypeListItem>> GetAnaesthesiaTypesAsync(
        int? branchId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AnaesthesiaTypeListItem>(
            "usp_Api_AnaesthesiaType_GetList",
            new { BranchId = branchId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 16. Anaesthesia Rate Master ───────────────────────────────────────────
    public async Task<IEnumerable<AnaesthesiaRateListItem>> GetAnaesthesiaRatesAsync(
        int? branchId = null, int? procedureId = null, int? anaesthesiaTypeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AnaesthesiaRateListItem>(
            "usp_Api_AnaesthesiaRate_GetList",
            new { BranchId = branchId, ProcedureId = procedureId, AnaesthesiaTypeId = anaesthesiaTypeId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 17. ICU Configuration Master ──────────────────────────────────────────
    public async Task<IEnumerable<IcuListItem>> GetIcusAsync(
        int? branchId = null, int? wardId = null, string? icuType = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<IcuListItem>(
            "usp_Api_Icu_GetList",
            new { BranchId = branchId, WardId = wardId, IcuType = icuType, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 18. ICU Tariff Master ─────────────────────────────────────────────────
    public async Task<IEnumerable<IcuTariffListItem>> GetIcuTariffsAsync(
        int? branchId = null, int? icuId = null, int? tariffCategoryId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<IcuTariffListItem>(
            "usp_Api_IcuTariff_GetList",
            new { BranchId = branchId, IcuId = icuId, TariffCategoryId = tariffCategoryId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    // ── 19. ICU Tariff Details ────────────────────────────────────────────────
    public async Task<IEnumerable<IcuTariffDetailItem>> GetIcuTariffDetailsAsync(int icuTariffId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<IcuTariffDetailItem>(
            "usp_Api_IcuTariffDetail_GetList",
            new { IcuTariffId = icuTariffId },
            commandType: CommandType.StoredProcedure);
    }
}





