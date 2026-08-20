using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>IPD Master Data API</summary>
[ApiController]
[Route("api/ipd-masters")]
[Produces("application/json")]
public class IpdMastersController(IIpdMasterService ipdMasterService) : ControllerBase
{
    // ── 1. Wards ──────────────────────────────────────────────────────────────
    [HttpGet("wards")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<WardListItem>>), 200)]
    public async Task<IActionResult> GetWards(
        [FromQuery] int? floorId,
        [FromQuery] int? departmentId,
        [FromQuery] string? wardType,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetWardsAsync(floorId, departmentId, wardType, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<WardListItem>>.Ok(list));
    }

    // ── 2. Nursing Stations ───────────────────────────────────────────────────
    [HttpGet("nursing-stations")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<NursingStationListItem>>), 200)]
    public async Task<IActionResult> GetNursingStations(
        [FromQuery] int? wardId,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetNursingStationsAsync(wardId, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<NursingStationListItem>>.Ok(list));
    }

    // ── 3. Rooms ──────────────────────────────────────────────────────────────
    [HttpGet("rooms")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<RoomListItem>>), 200)]
    public async Task<IActionResult> GetRooms(
        [FromQuery] int? buildingId,
        [FromQuery] int? floorId,
        [FromQuery] int? wardId,
        [FromQuery] string? roomCategory,
        [FromQuery] string? roomType,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetRoomsAsync(buildingId, floorId, wardId, roomCategory, roomType, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<RoomListItem>>.Ok(list));
    }

    // ── 4. Bed Categories ─────────────────────────────────────────────────────
    [HttpGet("bed-categories")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<BedCategoryListItem>>), 200)]
    public async Task<IActionResult> GetBedCategories(
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetBedCategoriesAsync(companyId, branchId);
        return Ok(ApiResponse<IEnumerable<BedCategoryListItem>>.Ok(list));
    }

    // ── 5. Beds ───────────────────────────────────────────────────────────────
    [HttpGet("beds")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<BedListItem>>), 200)]
    public async Task<IActionResult> GetBeds(
        [FromQuery] int? buildingId,
        [FromQuery] int? wardId,
        [FromQuery] int? roomId,
        [FromQuery] int? bedCategoryId,
        [FromQuery] string? bedStatus,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetBedsAsync(buildingId, wardId, roomId, bedCategoryId, bedStatus, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<BedListItem>>.Ok(list));
    }

    // ── 6. Tariff Categories ──────────────────────────────────────────────────
    [HttpGet("tariff-categories")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<TariffCategoryListItem>>), 200)]
    public async Task<IActionResult> GetTariffCategories(
        [FromQuery] string? patientCategory,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetTariffCategoriesAsync(patientCategory, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<TariffCategoryListItem>>.Ok(list));
    }

    // ── 7. Bed/Room Tariffs ───────────────────────────────────────────────────
    [HttpGet("bedroom-tariffs")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<BedRoomTariffListItem>>), 200)]
    public async Task<IActionResult> GetBedRoomTariffs(
        [FromQuery] int? wardId,
        [FromQuery] int? roomId,
        [FromQuery] int? bedCategoryId,
        [FromQuery] int? tariffCategoryId,
        [FromQuery] int? companyId,
        [FromQuery] int? branchId)
    {
        var list = await ipdMasterService.GetBedRoomTariffsAsync(wardId, roomId, bedCategoryId, tariffCategoryId, companyId, branchId);
        return Ok(ApiResponse<IEnumerable<BedRoomTariffListItem>>.Ok(list));
    }

    // ── 8. Hospital Services ──────────────────────────────────────────────────
    [HttpGet("hospital-services")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HospitalServiceListItem>>), 200)]
    public async Task<IActionResult> GetHospitalServices(
        [FromQuery] int? branchId,
        [FromQuery] int? departmentId,
        [FromQuery] string? serviceType,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetHospitalServicesAsync(branchId, departmentId, serviceType, companyId);
        return Ok(ApiResponse<IEnumerable<HospitalServiceListItem>>.Ok(list));
    }

    // ── 9. Hospital Service Rates ─────────────────────────────────────────────
    [HttpGet("hospital-service-rates")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<HospitalServiceRateListItem>>), 200)]
    public async Task<IActionResult> GetHospitalServiceRates(
        [FromQuery] int? branchId,
        [FromQuery] int? tariffCategoryId,
        [FromQuery] int? hospitalServiceId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetHospitalServiceRatesAsync(branchId, tariffCategoryId, hospitalServiceId, companyId);
        return Ok(ApiResponse<IEnumerable<HospitalServiceRateListItem>>.Ok(list));
    }

    // ── 10. Procedures ────────────────────────────────────────────────────────
    [HttpGet("procedures")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ProcedureListItem>>), 200)]
    public async Task<IActionResult> GetProcedures(
        [FromQuery] int? branchId,
        [FromQuery] int? departmentId,
        [FromQuery] int? specialityId,
        [FromQuery] string? procedureCategory,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetProceduresAsync(branchId, departmentId, specialityId, procedureCategory, companyId);
        return Ok(ApiResponse<IEnumerable<ProcedureListItem>>.Ok(list));
    }

    // ── 11. Procedure Tariffs ─────────────────────────────────────────────────
    [HttpGet("procedure-tariffs")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<ProcedureTariffListItem>>), 200)]
    public async Task<IActionResult> GetProcedureTariffs(
        [FromQuery] int? branchId,
        [FromQuery] int? tariffCategoryId,
        [FromQuery] int? procedureId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetProcedureTariffsAsync(branchId, tariffCategoryId, procedureId, companyId);
        return Ok(ApiResponse<IEnumerable<ProcedureTariffListItem>>.Ok(list));
    }

    // ── 12. OTs ───────────────────────────────────────────────────────────────
    [HttpGet("ots")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<OtListItem>>), 200)]
    public async Task<IActionResult> GetOts(
        [FromQuery] int? branchId,
        [FromQuery] int? floorId,
        [FromQuery] string? otType,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetOtsAsync(branchId, floorId, otType, companyId);
        return Ok(ApiResponse<IEnumerable<OtListItem>>.Ok(list));
    }

    // ── 13. OT Equipments ─────────────────────────────────────────────────────
    [HttpGet("ot-equipments")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<OtEquipmentListItem>>), 200)]
    public async Task<IActionResult> GetOtEquipments(
        [FromQuery] int? branchId,
        [FromQuery] int? otId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetOtEquipmentsAsync(branchId, otId, companyId);
        return Ok(ApiResponse<IEnumerable<OtEquipmentListItem>>.Ok(list));
    }

    // ── 14. OT Tariffs ────────────────────────────────────────────────────────
    [HttpGet("ot-tariffs")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<OtTariffListItem>>), 200)]
    public async Task<IActionResult> GetOtTariffs(
        [FromQuery] int? branchId,
        [FromQuery] int? tariffCategoryId,
        [FromQuery] int? otId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetOtTariffsAsync(branchId, tariffCategoryId, otId, companyId);
        return Ok(ApiResponse<IEnumerable<OtTariffListItem>>.Ok(list));
    }

    // ── 15. Anaesthesia Types ─────────────────────────────────────────────────
    [HttpGet("anaesthesia-types")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<AnaesthesiaTypeListItem>>), 200)]
    public async Task<IActionResult> GetAnaesthesiaTypes(
        [FromQuery] int? branchId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetAnaesthesiaTypesAsync(branchId, companyId);
        return Ok(ApiResponse<IEnumerable<AnaesthesiaTypeListItem>>.Ok(list));
    }

    // ── 16. Anaesthesia Rates ─────────────────────────────────────────────────
    [HttpGet("anaesthesia-rates")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<AnaesthesiaRateListItem>>), 200)]
    public async Task<IActionResult> GetAnaesthesiaRates(
        [FromQuery] int? branchId,
        [FromQuery] int? procedureId,
        [FromQuery] int? anaesthesiaTypeId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetAnaesthesiaRatesAsync(branchId, procedureId, anaesthesiaTypeId, companyId);
        return Ok(ApiResponse<IEnumerable<AnaesthesiaRateListItem>>.Ok(list));
    }

    // ── 17. ICU Configurations ────────────────────────────────────────────────
    [HttpGet("icus")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<IcuListItem>>), 200)]
    public async Task<IActionResult> GetIcus(
        [FromQuery] int? branchId,
        [FromQuery] int? wardId,
        [FromQuery] string? icuType,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetIcusAsync(branchId, wardId, icuType, companyId);
        return Ok(ApiResponse<IEnumerable<IcuListItem>>.Ok(list));
    }

    // ── 18. ICU Tariffs ───────────────────────────────────────────────────────
    [HttpGet("icu-tariffs")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<IcuTariffListItem>>), 200)]
    public async Task<IActionResult> GetIcuTariffs(
        [FromQuery] int? branchId,
        [FromQuery] int? icuId,
        [FromQuery] int? tariffCategoryId,
        [FromQuery] int? companyId)
    {
        var list = await ipdMasterService.GetIcuTariffsAsync(branchId, icuId, tariffCategoryId, companyId);
        return Ok(ApiResponse<IEnumerable<IcuTariffListItem>>.Ok(list));
    }

    // ── 19. ICU Tariff Details ────────────────────────────────────────────────
    [HttpGet("icu-tariffs/{tariffId:int}/details")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<IcuTariffDetailItem>>), 200)]
    public async Task<IActionResult> GetIcuTariffDetails([FromRoute] int tariffId)
    {
        var list = await ipdMasterService.GetIcuTariffDetailsAsync(tariffId);
        return Ok(ApiResponse<IEnumerable<IcuTariffDetailItem>>.Ok(list));
    }
}





