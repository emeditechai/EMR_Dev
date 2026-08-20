namespace EMR.Api.Models;

public class ReferralDoctorListItem
{
    public int ReferralDoctorId { get; set; }
    public string? Salutation { get; set; }
    public string DoctorName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? RegistrationNumber { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class DoctorSpecialityListItem
{
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class DoctorSubSpecialityListItem
{
    public int SubSpecialityId { get; set; }
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityCode { get; set; } = string.Empty;
    public string SubSpecialityName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class DepartmentListItem
{
    public int DeptId { get; set; }
    public string DeptCode { get; set; } = string.Empty;
    public string DeptName { get; set; } = string.Empty;
    public string DeptType { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class ClinicalUnitListItem
{
    public int UnitId { get; set; }
    public string UnitCode { get; set; } = string.Empty;
    public string UnitName { get; set; } = string.Empty;
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public int SpecialityId { get; set; }
    public string SpecialityName { get; set; } = string.Empty;
    public string SpecialityCode { get; set; } = string.Empty;
    public int? ConsultantInChargeDoctorId { get; set; }
    public string? ConsultantName { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class BuildingListItem
{
    public int BuildingId { get; set; }
    public string BuildingCode { get; set; } = string.Empty;
    public string BuildingName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int NumberOfFloors { get; set; }
    public int TotalFloorsConfigured { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class FloorListItem
{
    public int FloorId { get; set; }
    public string FloorCode { get; set; } = string.Empty;
    public string FloorName { get; set; } = string.Empty;
    public int BuildingId { get; set; }
    public string? BuildingName { get; set; }
    public string? BuildingCode { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class CountryListItem
{
    public int CountryId { get; set; }
    public string CountryCode { get; set; } = string.Empty;
    public string CountryName { get; set; } = string.Empty;
    public string? Currency { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class StateListItem
{
    public int StateId { get; set; }
    public string StateCode { get; set; } = string.Empty;
    public string StateName { get; set; } = string.Empty;
    public int CountryId { get; set; }
    public string? CountryName { get; set; }
    public CountryListItem? Country { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class DistrictListItem
{
    public int DistrictId { get; set; }
    public string DistrictCode { get; set; } = string.Empty;
    public string DistrictName { get; set; } = string.Empty;
    public int StateId { get; set; }
    public string? StateName { get; set; }
    public StateListItem? State { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class CityListItem
{
    public int CityId { get; set; }
    public string CityCode { get; set; } = string.Empty;
    public string CityName { get; set; } = string.Empty;
    public int DistrictId { get; set; }
    public string? DistrictName { get; set; }
    public DistrictListItem? District { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class AreaListItem
{
    public int AreaId { get; set; }
    public string AreaCode { get; set; } = string.Empty;
    public string AreaName { get; set; } = string.Empty;
    public int CityId { get; set; }
    public string? CityName { get; set; }
    public CityListItem? City { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
