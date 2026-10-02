namespace EMR.Api.Models;

public class ServiceListItem
{
    public int ServiceId { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    /// <summary>ServiceMaster.ItemName - the name the Service Master list shows (usp_Api_Service_GetList returns the table's columns).</summary>
    public string ItemName { get; set; } = string.Empty;
    public string ServiceType { get; set; } = string.Empty;
    public bool IsRegistration { get; set; }
    public string? ConsultingType { get; set; }
    public bool IsGstRequired { get; set; }
    /// <summary>Service Master > Is Discountable (script 2190).</summary>
    public bool IsDiscountable { get; set; } = true;
    public string? SacCode { get; set; }
    public decimal ItemCharges { get; set; }
    public decimal? GstPercentage { get; set; }
    public bool IsActive { get; set; }
    public int BranchId { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class DoctorRoomListItem
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public int FloorId { get; set; }
    public string? FloorName { get; set; }
    public int BranchId { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class OPDDoctorOptionDto
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string SpecialityName { get; set; } = string.Empty;
}

public class RoomDoctorAssignmentListItem
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public string FloorName { get; set; } = string.Empty;
    public string AssignedDoctors { get; set; } = string.Empty;
    public List<OPDDoctorOptionDto> Doctors { get; set; } = new();
}

public class EmrInvestigationListItem
{
    public int InvestigationId { get; set; }
    public string InvestigationName { get; set; } = string.Empty;
    public string? Category { get; set; }
    public string? SampleType { get; set; }
    public string? NormalRange { get; set; }
    public string? Unit { get; set; }
    public decimal? DefaultCost { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class EmrMedicationListItem
{
    public int MedicationId { get; set; }
    public string MedicationName { get; set; } = string.Empty;
    public string? GenericName { get; set; }
    public string? Category { get; set; }
    public string? DosageForm { get; set; }
    public string? Strength { get; set; }
    public string? DefaultDosage { get; set; }
    public string? DefaultFrequency { get; set; }
    public string? DefaultDuration { get; set; }
    public string? Instructions { get; set; }
    public bool IsActive { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
