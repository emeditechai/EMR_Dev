namespace EMR.Api.Models;

// Master > Lab Master > Phlebotomist Barcode Assignment (SQLScripts/2401)

public class LabPhleboBarcodePhlebotomistModel
{
    public int PhlebotomistId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Username { get; set; }
    public string PhleboCode { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public int AvailableCount { get; set; }
    public int UsedCount { get; set; }
    public int SeriesCount { get; set; }
}

public class LabPhleboBarcodeSeriesModel
{
    public int SeriesId { get; set; }
    public string SeriesCode { get; set; } = string.Empty;
    public int PhlebotomistId { get; set; }
    public string? PhleboCode { get; set; }
    public int BranchId { get; set; }
    public string? BranchCode { get; set; }
    public string FinancialYear { get; set; } = string.Empty;
    public int StartNumber { get; set; }
    public int EndNumber { get; set; }
    public int Quantity { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? SampleCategoryCode { get; set; }
    public string? SampleCategoryName { get; set; }
    public DateTime GeneratedDate { get; set; }
    public string? GeneratedByName { get; set; }
    public DateTime? CancelledDate { get; set; }
    public string? CancelledByName { get; set; }
    public string? CancelReason { get; set; }
    public string? StartBarcode { get; set; }
    public string? EndBarcode { get; set; }
    public int AvailableCount { get; set; }
    public int UsedCount { get; set; }
    public int VoidedCount { get; set; }
}

public class LabPhleboBarcodeGeneratedModel
{
    public int SeriesId { get; set; }
    public string SeriesCode { get; set; } = string.Empty;
    public string? SampleCategoryCode { get; set; }
    public string StartBarcode { get; set; } = string.Empty;
    public string EndBarcode { get; set; } = string.Empty;
    public int Quantity { get; set; }
}

public class LabPhleboBarcodeModel
{
    public long BarcodeId { get; set; }
    public string BarcodeNo { get; set; } = string.Empty;
    public int SequenceNo { get; set; }
    public byte Status { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public string? SeriesCode { get; set; }
    public string? SeriesStatus { get; set; }
    public string? SampleCategoryCode { get; set; }
    public int PhlebotomistId { get; set; }
    public string? PhlebotomistName { get; set; }
    public string? BillNo { get; set; }
    public string? Test_Name { get; set; }
    public DateTime? UsedDate { get; set; }
    public DateTime? VoidedDate { get; set; }
    public string? VoidReason { get; set; }
}

public record LabPhleboBarcodeGenerateRequest(int CompanyId, int BranchId, int PhlebotomistId, int Quantity, string? SampleCategoryCode, int? CreatedBy);
public record LabPhleboBarcodeCancelRequest(int BranchId, string Reason, int? UserId);
/// <summary>For the phlebotomist app (later): validate a scanned barcode and mark it used for the sample.</summary>
public record LabPhleboBarcodeConsumeRequest(string BarcodeNo, int PhlebotomistId, int? LabOrderId, long? SamplecollectionID, int? UserId);
