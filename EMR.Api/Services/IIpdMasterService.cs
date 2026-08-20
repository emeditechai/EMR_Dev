using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IIpdMasterService
{
    Task<IEnumerable<WardListItem>> GetWardsAsync(
        int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<NursingStationListItem>> GetNursingStationsAsync(
        int? wardId = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<RoomListItem>> GetRoomsAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedCategoryListItem>> GetBedCategoriesAsync(
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedListItem>> GetBedsAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<TariffCategoryListItem>> GetTariffCategoriesAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedRoomTariffListItem>> GetBedRoomTariffsAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<HospitalServiceListItem>> GetHospitalServicesAsync(
        int? branchId = null, int? departmentId = null, string? serviceType = null, int? companyId = null);

    Task<IEnumerable<HospitalServiceRateListItem>> GetHospitalServiceRatesAsync(
        int? branchId = null, int? tariffCategoryId = null, int? hospitalServiceId = null, int? companyId = null);

    Task<IEnumerable<ProcedureListItem>> GetProceduresAsync(
        int? branchId = null, int? departmentId = null, int? specialityId = null, string? procedureCategory = null, int? companyId = null);

    Task<IEnumerable<ProcedureTariffListItem>> GetProcedureTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? procedureId = null, int? companyId = null);

    Task<IEnumerable<OtListItem>> GetOtsAsync(
        int? branchId = null, int? floorId = null, string? otType = null, int? companyId = null);

    Task<IEnumerable<OtEquipmentListItem>> GetOtEquipmentsAsync(
        int? branchId = null, int? otId = null, int? companyId = null);

    Task<IEnumerable<OtTariffListItem>> GetOtTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? otId = null, int? companyId = null);

    Task<IEnumerable<AnaesthesiaTypeListItem>> GetAnaesthesiaTypesAsync(
        int? branchId = null, int? companyId = null);

    Task<IEnumerable<AnaesthesiaRateListItem>> GetAnaesthesiaRatesAsync(
        int? branchId = null, int? procedureId = null, int? anaesthesiaTypeId = null, int? companyId = null);

    Task<IEnumerable<IcuListItem>> GetIcusAsync(
        int? branchId = null, int? wardId = null, string? icuType = null, int? companyId = null);

    Task<IEnumerable<IcuTariffListItem>> GetIcuTariffsAsync(
        int? branchId = null, int? icuId = null, int? tariffCategoryId = null, int? companyId = null);

    Task<IEnumerable<IcuTariffDetailItem>> GetIcuTariffDetailsAsync(int icuTariffId);
}
