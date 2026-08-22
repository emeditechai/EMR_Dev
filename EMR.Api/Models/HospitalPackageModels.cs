namespace EMR.Api.Models;

/// <summary>Hospital Package list item model returned by usp_HospitalPackage_GetList</summary>
public class HospitalPackageListItemDto
{
    public int HospitalPackage_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Package_Code { get; set; } = string.Empty;
    public string Package_Name { get; set; } = string.Empty;
    public string Package_Type { get; set; } = string.Empty;
    public DateTime ValidFrom { get; set; }
    public DateTime? ValidTo { get; set; }
    public decimal TotalPackageAmount { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int TotalDetailsCount { get; set; }
    public int DistinctHeadsCount { get; set; }
}

/// <summary>Hospital Package Header model</summary>
public class HospitalPackageHeaderDto
{
    public int HospitalPackage_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Package_Code { get; set; } = string.Empty;
    public string Package_Name { get; set; } = string.Empty;
    public string Package_Type { get; set; } = string.Empty;
    public DateTime ValidFrom { get; set; }
    public DateTime? ValidTo { get; set; }
    public decimal TotalPackageAmount { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public List<HospitalPackageDetailDto> Details { get; set; } = [];
}

/// <summary>Hospital Package Detail Line Item model</summary>
public class HospitalPackageDetailDto
{
    public int HospitalPackageDetail_ID { get; set; }
    public int HospitalPackage_ID { get; set; }
    public string DetailHeadType { get; set; } = string.Empty;
    public int? MasterReferenceId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal Quantity { get; set; } = 1;
    public decimal UnitRate { get; set; } = 0;
    public decimal Amount { get; set; } = 0;
    public string BillingFrequency { get; set; } = "Package Included";
    public bool IsMandatory { get; set; } = true;
    public string? Remarks { get; set; }
    public int DisplayOrder { get; set; }
}

/// <summary>Hospital Package Create/Update Request</summary>
public class HospitalPackageSaveRequest
{
    public int HospitalPackage_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string Package_Code { get; set; } = string.Empty;
    public string Package_Name { get; set; } = string.Empty;
    public string Package_Type { get; set; } = string.Empty;
    public DateTime ValidFrom { get; set; } = DateTime.Today;
    public DateTime? ValidTo { get; set; }
    public decimal TotalPackageAmount { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
    public List<HospitalPackageDetailDto> Details { get; set; } = [];
}

/// <summary>Master lookup item for Bed, Room, Procedure, Doctor fee, Nursing, OT, Anaesthesia, Consumables, Equipment, Services</summary>
public class MasterLookupItemDto
{
    public string DetailHeadType { get; set; } = string.Empty;
    public int? MasterReferenceId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal DefaultRate { get; set; }
    public string DefaultBillingFrequency { get; set; } = "Package Included";
}
