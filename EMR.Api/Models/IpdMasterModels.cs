namespace EMR.Api.Models;

public class WardListItem
{
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string? BuildingName { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string WardType { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public int Capacity { get; set; }
    public bool IsIsolationWard { get; set; }
    public int TotalNursingStations { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class NursingStationListItem
{
    public int NursingStationId { get; set; }
    public string StationCode { get; set; } = string.Empty;
    public string StationName { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string? FloorName { get; set; }
    public string? ResponsibleNurse { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class RoomListItem
{
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string FloorCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public string? WardType { get; set; }
    public string RoomType { get; set; } = string.Empty;
    public string RoomCategory { get; set; } = string.Empty;
    public bool IsIsolation { get; set; }
    public int BedCapacity { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BedCategoryListItem
{
    public int BedCategoryId { get; set; }
    public string? CategoryCode { get; set; }
    public string CategoryName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BedListItem
{
    public int BedId { get; set; }
    public string BedNumber { get; set; } = string.Empty;
    public int BuildingId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public string? BedCategoryCode { get; set; }
    public string BedStatus { get; set; } = "Available";
    public bool IsIsolation { get; set; }
    public bool IsICU { get; set; }
    public bool IsVentilatorCapable { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class TariffCategoryListItem
{
    public int TariffCategoryId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string PatientCategory { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BedRoomTariffListItem
{
    public int BedRateId { get; set; }
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public decimal RoomCharge { get; set; }
    public decimal BedCharge { get; set; }
    public decimal NursingCharge { get; set; }
    public decimal AttendantCharge { get; set; }
    public decimal IsolationCharge { get; set; }
    public decimal GstPercentage { get; set; }
    public bool IsActive { get; set; }
}

public class HospitalServiceListItem
{
    public int HospitalServiceId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public string ServiceCode { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    public string ServiceType { get; set; } = string.Empty;
    public string UOM { get; set; } = string.Empty;
    public decimal TaxPercentage { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class HospitalServiceRateListItem
{
    public int ServiceRateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int HospitalServiceId { get; set; }
    public string ServiceCode { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    public string ServiceType { get; set; } = string.Empty;
    public string UOM { get; set; } = string.Empty;
    public decimal TaxPercentage { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public decimal Rate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class ProcedureListItem
{
    public int ProcedureId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string? DepartmentCode { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string? SpecialityCode { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public int DurationHours { get; set; }
    public int DurationMinutes { get; set; }
    public int DurationSeconds { get; set; }
    public bool AnaesthesiaRequired { get; set; }
    public bool ConsentRequired { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class ProcedureTariffListItem
{
    public int ProcedureTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;
    public string SpecialityName { get; set; } = string.Empty;
    public decimal SurgeonFee { get; set; }
    public decimal AssistantFee { get; set; }
    public decimal AnaesthetistFee { get; set; }
    public decimal OtCharges { get; set; }
    public decimal EquipmentCharges { get; set; }
    public decimal ConsumableCharges { get; set; }
    public decimal NursingCharges { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class OtListItem
{
    public int OtId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int FloorId { get; set; }
    public string FloorName { get; set; } = string.Empty;
    public string? FloorCode { get; set; }
    public int? BuildingId { get; set; }
    public string? BuildingName { get; set; }
    public string? BuildingCode { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string Capacity { get; set; } = string.Empty;
    public bool EmergencyAvailable { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class OtEquipmentListItem
{
    public int EquipmentId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int OtId { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string? FloorName { get; set; }
    public string? BuildingName { get; set; }
    public string EquipmentCode { get; set; } = string.Empty;
    public string EquipmentName { get; set; } = string.Empty;
    public string? EquipmentType { get; set; }
    public string? SerialNo { get; set; }
    public bool CalibrationRequired { get; set; }
    public DateTime? LastCalibrationDate { get; set; }
    public DateTime? CalibrationDueDate { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class OtTariffListItem
{
    public int OtTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public int OtId { get; set; }
    public string OtCode { get; set; } = string.Empty;
    public string OtName { get; set; } = string.Empty;
    public string OtType { get; set; } = string.Empty;
    public string? FloorName { get; set; }
    public string? BuildingName { get; set; }
    public decimal OtUsageRate { get; set; }
    public decimal NursingCharges { get; set; }
    public decimal EquipmentCharges { get; set; }
    public decimal RecoveryCharges { get; set; }
    public decimal ConsumableCharges { get; set; }
    public decimal SpecialEquipmentCharges { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class AnaesthesiaTypeListItem
{
    public int AnaesthesiaTypeId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public string TypeCode { get; set; } = string.Empty;
    public string TypeName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int TotalRatesConfigured { get; set; }
}

public class AnaesthesiaRateListItem
{
    public int AnaesthesiaRateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string ProcedureCategory { get; set; } = string.Empty;
    public string? DepartmentName { get; set; }
    public int AnaesthesiaTypeId { get; set; }
    public string AnaesthesiaTypeCode { get; set; } = string.Empty;
    public string AnaesthesiaTypeName { get; set; } = string.Empty;
    public decimal AnaesthetistFee { get; set; }
    public decimal ConsumableCharge { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class IcuListItem
{
    public int IcuId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int WardId { get; set; }
    public string WardCode { get; set; } = string.Empty;
    public string WardName { get; set; } = string.Empty;
    public int? FloorId { get; set; }
    public string? FloorName { get; set; }
    public string? FloorCode { get; set; }
    public string? BuildingName { get; set; }
    public string IcuCode { get; set; } = string.Empty;
    public string IcuName { get; set; } = string.Empty;
    public string IcuType { get; set; } = string.Empty;
    public int BedCapacity { get; set; }
    public int VentilatorCapacity { get; set; }
    public int IsolationCapacity { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int ActiveTariffsCount { get; set; }
    public int TotalTariffsCount { get; set; }
}

public class IcuTariffListItem
{
    public int IcuTariffId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int IcuId { get; set; }
    public string IcuCode { get; set; } = string.Empty;
    public string IcuName { get; set; } = string.Empty;
    public string IcuType { get; set; } = string.Empty;
    public string? WardName { get; set; }
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? PatientCategory { get; set; }
    public decimal TotalRate { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public int TotalRateHeadsCount { get; set; }
    public string? RateHeadsSummary { get; set; }
}

public class IcuTariffDetailItem
{
    public int IcuTariffDetailId { get; set; }
    public int IcuTariffId { get; set; }
    public string RateHeadName { get; set; } = string.Empty;
    public string? RateHeadCode { get; set; }
    public decimal RateAmount { get; set; }
    public string BillingFrequency { get; set; } = "Per Day";
    public bool IsMandatory { get; set; }
    public string? Remarks { get; set; }
    public int DisplayOrder { get; set; }
}




