namespace EMR.Api.Models;

/// <summary>One allocation batch of pre-printed barcodes for a Franchise (Master &gt; Lab Master &gt; Franchise Barcode Assignment).</summary>
public class LabFranchiseBarcodeSeriesModel
{
    public int SeriesId { get; set; }
    public string SeriesCode { get; set; } = string.Empty;
    public int Franchise_ID { get; set; }
    public int BranchId { get; set; }
    public string? BranchCode { get; set; }
    public string FinancialYear { get; set; } = string.Empty;
    public int StartNumber { get; set; }
    public int EndNumber { get; set; }
    public int Quantity { get; set; }
    public string Status { get; set; } = string.Empty;
    /// <summary>NULL = General (no category); otherwise F / PP / U.</summary>
    public string? SampleCategoryCode { get; set; }
    public string? SampleCategoryName { get; set; }
    public DateTime GeneratedDate { get; set; }
    public string? GeneratedByName { get; set; }
    public DateTime? CancelledDate { get; set; }
    public string? CancelledByName { get; set; }
    public string? CancelReason { get; set; }
    public string? Franchise_Code { get; set; }
    public int AvailableCount { get; set; }
    public int UsedCount { get; set; }
    public int VoidedCount { get; set; }
}

/// <summary>Result of generating a new series.</summary>
public class LabFranchiseBarcodeSeriesGeneratedModel
{
    public int SeriesId { get; set; }
    public string SeriesCode { get; set; } = string.Empty;
    public string? SampleCategoryCode { get; set; }
    public string StartBarcode { get; set; } = string.Empty;
    public string EndBarcode { get; set; } = string.Empty;
    public int Quantity { get; set; }
}

public class GenerateBarcodeSeriesRequestModel
{
    public int Franchise_ID { get; set; }
    public int Quantity { get; set; }
    /// <summary>Optional: F (Fasting), PP (PP / Post Prandial), U (Urine). Null/blank = General (existing, unsuffixed pattern).</summary>
    public string? SampleCategoryCode { get; set; }
    public int? CreatedBy { get; set; }
}

public class CancelBarcodeSeriesRequestModel
{
    public string Reason { get; set; } = string.Empty;
    public int? UserId { get; set; }
}

/// <summary>One code of a series - the audit ledger row.</summary>
public class LabFranchiseBarcodePoolModel
{
    public long BarcodeId { get; set; }
    public string BarcodeNo { get; set; } = string.Empty;
    public byte Status { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public int Franchise_ID { get; set; }
    public string? Franchise_Code { get; set; }
    public string? Franchise_Name { get; set; }
    public int SeriesId { get; set; }
    public string? SeriesCode { get; set; }
    public string? SeriesStatus { get; set; }
    public string? SampleCategoryCode { get; set; }
    public string? SampleCategoryName { get; set; }
    public int? LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public long? SamplecollectionID { get; set; }
    public int? InvestigationId { get; set; }
    public string? Test_Name { get; set; }
    public DateTime? UsedDate { get; set; }
    public string? UsedByName { get; set; }
}

public class ValidateConsumeBarcodeRequestModel
{
    public string BarcodeNo { get; set; } = string.Empty;
    public int Franchise_ID { get; set; }
    public int LabOrderId { get; set; }
    public long SamplecollectionID { get; set; }
    public int? InvestigationId { get; set; }
    public int? UserId { get; set; }
}

public class ValidateConsumeBarcodeResponseModel
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public string BarcodeNo { get; set; } = string.Empty;
}
