using System.Text.Json;

namespace EMR.Api.Models;

/// <summary>Pharmacy masters (SQLScripts/2357): value / text pair of a drop-down.</summary>
public class PhOptionDto
{
    public string Value { get; set; } = "";
    public string Text { get; set; } = "";
}

/// <summary>Save of a simple pharmacy master: the field values already checked by EMR.Web, keyed by column name.</summary>
public class PhMasterSaveRequest
{
    public int Id { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int UserId { get; set; }
    public bool IsActive { get; set; } = true;
    public Dictionary<string, JsonElement> Values { get; set; } = new();
}

public class PhSaveResult
{
    public int Id { get; set; }
    public string? Error { get; set; }
}

public class PhCompanyBranchRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
}

public class PhItemListRowDto
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string? CategoryName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string HsnCode { get; set; } = "";
    public decimal GstPercent { get; set; }
    public string PurchaseUom { get; set; } = "";
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool IsColdChain { get; set; }
    public bool IsHighAlert { get; set; }
    public bool IsLasa { get; set; }
    public bool PrescriptionRequired { get; set; }
    public string? RackNo { get; set; }
    public bool IsActive { get; set; }
    public int TotalCount { get; set; }
}

public class PhItemDto
{
    public int ItemId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = "";
    public int? GenericId { get; set; }
    public int? ManufacturerId { get; set; }
    public int CategoryId { get; set; }
    public int? DosageFormId { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string ScheduleCode { get; set; } = "H";
    public int HsnId { get; set; }
    public int PurchaseUomId { get; set; }
    public int SaleUomId { get; set; }
    public int ConversionQty { get; set; } = 1;
    public bool AllowLooseSale { get; set; } = true;
    public bool IsColdChain { get; set; }
    public bool IsHighAlert { get; set; }
    public bool IsLasa { get; set; }
    public bool IsReturnable { get; set; } = true;
    public bool IsDiscountAllowed { get; set; } = true;
    public bool PrescriptionRequired { get; set; } = true;
    public string? Barcode { get; set; }
    public decimal ReorderLevel { get; set; }
    public decimal MinQty { get; set; }
    public decimal MaxQty { get; set; }
    public int LeadDays { get; set; } = 2;
    public string? VedClass { get; set; }
    public string? Remarks { get; set; }
    public bool IsActive { get; set; } = true;
    public string? RackNo { get; set; }
    public decimal? BranchReorderLevel { get; set; }
    public decimal? BranchMinQty { get; set; }
    public decimal? BranchMaxQty { get; set; }
    public bool IsStocked { get; set; } = true;
}

public class PhItemSaveRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int UserId { get; set; }
    public PhItemDto Item { get; set; } = new();
}

public class PhHsnOptionDto
{
    public int Id { get; set; }
    public string Code { get; set; } = "";
    public string Description { get; set; } = "";
    public decimal Gst { get; set; }
}

public class PhScheduleOptionDto
{
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Warning { get; set; }
    public bool Rx { get; set; }
}

public class PhItemLookupsDto
{
    public List<PhOptionDto> Generics { get; set; } = [];
    public List<PhOptionDto> Manufacturers { get; set; } = [];
    public List<PhOptionDto> Categories { get; set; } = [];
    public List<PhOptionDto> DosageForms { get; set; } = [];
    public List<PhOptionDto> Uoms { get; set; } = [];
    public List<PhHsnOptionDto> Hsn { get; set; } = [];
    public List<PhScheduleOptionDto> Schedules { get; set; } = [];
}

public class PhItemCountsDto
{
    public int Total { get; set; }
    public int Active { get; set; }
}
