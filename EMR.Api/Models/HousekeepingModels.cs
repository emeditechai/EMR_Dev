namespace EMR.Api.Models;

// ── HK Location Models ───────────────────────────────────────────────────────
public class HKLocationListItemDto
{
    public int Location_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string LocationType { get; set; } = string.Empty;
    public int Reference_ID { get; set; }
    public string? ReferenceEntityName { get; set; }
    public string LocationCode { get; set; } = string.Empty;
    public string LocationName { get; set; } = string.Empty;
    public int? Floor_ID { get; set; }
    public string? FloorName { get; set; }
    public int? Building_ID { get; set; }
    public string? BuildingName { get; set; }
    public string RiskLevel { get; set; } = "Moderate Risk";
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int AssignedStaffCount { get; set; }
}

public class HKLocationDetailDto : HKLocationListItemDto
{
}

public class HKLocationSaveRequest
{
    public int? Location_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string LocationType { get; set; } = "Ward";
    public int Reference_ID { get; set; } = 0;
    public string LocationCode { get; set; } = string.Empty;
    public string LocationName { get; set; } = string.Empty;
    public int? Floor_ID { get; set; }
    public int? Building_ID { get; set; }
    public string RiskLevel { get; set; } = "Moderate Risk";
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class HKPhysicalMasterItemDto
{
    public int Reference_ID { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public int? Floor_ID { get; set; }
    public int? Building_ID { get; set; }
}

// ── HK Cleaning Models ───────────────────────────────────────────────────────
public class HKCleaningListItemDto
{
    public int Cleaning_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string CleaningType { get; set; } = string.Empty;
    public string Frequency { get; set; } = string.Empty;
    public int? ChecklistTemplate_ID { get; set; }
    public string? ChecklistTemplateName { get; set; }
    public string? ChecklistTemplateCode { get; set; }
    public string ChemicalUsed { get; set; } = string.Empty;
    public string EquipmentUsed { get; set; } = string.Empty;
    public int SLA_Minutes { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class HKCleaningDetailDto : HKCleaningListItemDto
{
}

public class HKCleaningSaveRequest
{
    public int? Cleaning_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string CleaningType { get; set; } = string.Empty;
    public string Frequency { get; set; } = string.Empty;
    public int? ChecklistTemplate_ID { get; set; }
    public string ChemicalUsed { get; set; } = string.Empty;
    public string EquipmentUsed { get; set; } = string.Empty;
    public int SLA_Minutes { get; set; } = 30;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

// ── HK Staff Models ─────────────────────────────────────────────────────────
public class HKStaffListItemDto
{
    public int HKStaff_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public int Staff_ID { get; set; }
    public string? StaffUsername { get; set; }
    public string? StaffName { get; set; }
    public string? StaffPhone { get; set; }
    public int ShiftMaster_ID { get; set; }
    public string? ShiftCode { get; set; }
    public string? ShiftName { get; set; }
    public TimeSpan ShiftStartTime { get; set; }
    public TimeSpan ShiftEndTime { get; set; }
    public int? Supervisor_ID { get; set; }
    public string? SupervisorUsername { get; set; }
    public string? SupervisorName { get; set; }
    public int AreaAllocation_ID { get; set; }
    public string? LocationCode { get; set; }
    public string? LocationName { get; set; }
    public string? LocationType { get; set; }
    public string? RiskLevel { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class HKStaffDetailDto : HKStaffListItemDto
{
}

public class HKStaffSaveRequest
{
    public int? HKStaff_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public int Staff_ID { get; set; }
    public int ShiftMaster_ID { get; set; }
    public int? Supervisor_ID { get; set; }
    public int AreaAllocation_ID { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

// ── HK Checklist Template Models ────────────────────────────────────────────
public class HKChecklistTemplateDto
{
    public int Template_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string TemplateCode { get; set; } = string.Empty;
    public string TemplateName { get; set; } = string.Empty;
    public string? ChecklistItemsJSON { get; set; }
    public bool IsActive { get; set; }
}
