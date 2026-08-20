using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IIpdMasterApiClient
{
    Task<IEnumerable<WardListItemViewModel>> GetWardsAsync(
        int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<NursingStationListItemViewModel>> GetNursingStationsAsync(
        int? wardId = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<RoomListItemViewModel>> GetRoomsAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedCategoryListItemViewModel>> GetBedCategoriesAsync(
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedListItemViewModel>> GetBedsAsync(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null, 
        int? companyId = null, int? branchId = null);

    Task<IEnumerable<TariffCategoryListItemViewModel>> GetTariffCategoriesAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<BedRoomTariffListItemViewModel>> GetBedRoomTariffsAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null);

    Task<IEnumerable<HospitalServiceListItemViewModel>> GetHospitalServicesAsync(
        int? branchId = null, int? departmentId = null, string? serviceType = null, int? companyId = null);

    Task<IEnumerable<HospitalServiceRateListItemViewModel>> GetHospitalServiceRatesAsync(
        int? branchId = null, int? tariffCategoryId = null, int? hospitalServiceId = null, int? companyId = null);

    Task<IEnumerable<ProcedureListItemViewModel>> GetProceduresAsync(
        int? branchId = null, int? departmentId = null, int? specialityId = null, string? procedureCategory = null, int? companyId = null);

    Task<IEnumerable<ProcedureTariffListItemViewModel>> GetProcedureTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? procedureId = null, int? companyId = null);

    Task<IEnumerable<OtListItemViewModel>> GetOtsAsync(
        int? branchId = null, int? floorId = null, string? otType = null, int? companyId = null);

    Task<IEnumerable<OtEquipmentListItemViewModel>> GetOtEquipmentsAsync(
        int? branchId = null, int? otId = null, int? companyId = null);

    Task<IEnumerable<OtTariffListItemViewModel>> GetOtTariffsAsync(
        int? branchId = null, int? tariffCategoryId = null, int? otId = null, int? companyId = null);

    Task<IEnumerable<AnaesthesiaTypeListItemViewModel>> GetAnaesthesiaTypesAsync(
        int? branchId = null, int? companyId = null);

    Task<IEnumerable<AnaesthesiaRateListItemViewModel>> GetAnaesthesiaRatesAsync(
        int? branchId = null, int? procedureId = null, int? anaesthesiaTypeId = null, int? companyId = null);

    Task<IEnumerable<IcuListItemViewModel>> GetIcusAsync(
        int? branchId = null, int? wardId = null, string? icuType = null, int? companyId = null);

    Task<IEnumerable<IcuTariffListItemViewModel>> GetIcuTariffsAsync(
        int? branchId = null, int? icuId = null, int? tariffCategoryId = null, int? companyId = null);

    Task<IEnumerable<IcuTariffDetailFormViewModel>> GetIcuTariffDetailsAsync(int icuTariffId);
}
