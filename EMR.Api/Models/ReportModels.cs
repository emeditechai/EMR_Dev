namespace EMR.Api.Models;

public class DailyCollectionRegisterItem
{
    // One receipt (EntryType = RECEIPT) or one refund paid out (EntryType = REFUND) in the period -
    // usp_Api_Report_DailyCollectionRegister (script 2192). Bill amounts describe the bill the receipt was taken against.
    public string EntryType { get; set; } = "RECEIPT";
    public int EntryId { get; set; }
    public int? PaymentHeaderId { get; set; }
    public DateTime PaymentDate { get; set; }
    public string? ReceiptNo { get; set; }
    public string? ModuleCode { get; set; }
    public int? ModuleRefId { get; set; }
    public string BillNo { get; set; } = string.Empty;
    public string? TokenNo { get; set; }
    public DateTime? BillDate { get; set; }
    /// <summary>'F' bill fully cancelled, 'P' partly cancelled, null not cancelled (script 2194).</summary>
    public string? CancellationType { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public string? PhoneNumber { get; set; }
    public string? DoctorName { get; set; }

    public decimal BillAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal BalanceDue { get; set; }
    public string? PaymentStatus { get; set; }

    /// <summary>The receipt's amount (or the refund's).</summary>
    public decimal Amount { get; set; }
    public string? PaymentMode { get; set; }
    public string? Reference { get; set; }
    public string? CollectedBy { get; set; }
}

public class PatientRegisterItem
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? Gender { get; set; }
    public int? Age { get; set; }
    public DateTime RegistrationDate { get; set; }
    public string? RelationName { get; set; }
    public string? ParentName { get; set; }
}

// ── Reports > LAB > B2C Collection Register (usp_Api_LabReport_B2CCollectionRegister) ──
public class B2CCollectionSummary
{
    public int ReceiptCount { get; set; }
    public decimal TotalCollection { get; set; }
    public int BillCount { get; set; }
    public int PatientCount { get; set; }
    public decimal AvgPerReceipt { get; set; }
    public decimal HighestReceipt { get; set; }
    public decimal CancelledBillCollection { get; set; }
    public int CancelledBillReceipts { get; set; }
}

public class B2CCollectionModeRow
{
    public int? PaymentMethodId { get; set; }
    public string PaymentMode { get; set; } = string.Empty;
    public int ReceiptCount { get; set; }
    public decimal Amount { get; set; }
}

public class B2CCollectionDayRow
{
    public DateTime CollectionDate { get; set; }
    public int ReceiptCount { get; set; }
    public decimal Amount { get; set; }
}

public class B2CCollectionCollectorRow
{
    public int? CollectedById { get; set; }
    public string CollectedBy { get; set; } = string.Empty;
    public int ReceiptCount { get; set; }
    public decimal Amount { get; set; }
}

public class B2CCollectionReceiptRow
{
    public int PaymentDetailId { get; set; }
    public string? ReceiptNo { get; set; }
    public DateTime ReceiptDate { get; set; }
    public decimal PaidAmount { get; set; }
    public int? PaymentMethodId { get; set; }
    public string PaymentMode { get; set; } = string.Empty;
    public string? PaymentReference { get; set; }
    public string? BankName { get; set; }
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public DateTime BillDate { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public string? PhoneNumber { get; set; }
    public decimal BillNetAmount { get; set; }
    public decimal BillTotalPaid { get; set; }
    public decimal BillBalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public bool IsBillActive { get; set; }
    public int? CollectedById { get; set; }
    public string CollectedBy { get; set; } = string.Empty;
}

public class B2CCollectionPaymentMethod
{
    public int PaymentMethodId { get; set; }
    public string MethodName { get; set; } = string.Empty;
}

public class B2CCollectionRegisterResult
{
    public B2CCollectionSummary Summary { get; set; } = new();
    public List<B2CCollectionModeRow> ByMode { get; set; } = new();
    public List<B2CCollectionDayRow> ByDay { get; set; } = new();
    public List<B2CCollectionCollectorRow> ByCollector { get; set; } = new();
    public List<B2CCollectionReceiptRow> Receipts { get; set; } = new();
    public List<B2CCollectionPaymentMethod> PaymentMethods { get; set; } = new();
}

// ── Reports > LAB > Discount Register (usp_Api_LabReport_DiscountRegister) ──
public class DiscountRegisterSummary
{
    public int BillCount { get; set; }
    public decimal TotalDiscount { get; set; }
    public decimal GrossOfDiscountedBills { get; set; }
    public decimal DiscountPercent { get; set; }
    public decimal HighestDiscount { get; set; }
    public int WithoutReasonCount { get; set; }
    public decimal WithoutReasonAmount { get; set; }
}

public class DiscountRegisterGroupRow
{
    public int? ApprovedById { get; set; }
    public int? EnteredById { get; set; }
    public string GroupName { get; set; } = string.Empty;
    public int BillCount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal GrossAmount { get; set; }
}

public class DiscountRegisterBillRow
{
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public DateTime BillDate { get; set; }
    public string BillingType { get; set; } = "B2C";
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public string? PhoneNumber { get; set; }
    public decimal GrossAmount { get; set; }
    public string? DiscountType { get; set; }
    public decimal? DiscountValue { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal DiscountPercent { get; set; }
    public decimal NetAmount { get; set; }
    public decimal PaidAmount { get; set; }
    public decimal BalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public bool IsBillActive { get; set; }
    public string? DiscountReason { get; set; }
    public int? ApprovedById { get; set; }
    public string? ApprovedBy { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public int? EnteredById { get; set; }
    public string? EnteredBy { get; set; }
}

public class DiscountRegisterResult
{
    public DiscountRegisterSummary Summary { get; set; } = new();
    public List<DiscountRegisterGroupRow> ByApprover { get; set; } = new();
    public List<DiscountRegisterGroupRow> ByReason { get; set; } = new();
    public List<DiscountRegisterGroupRow> ByEnteredBy { get; set; } = new();
    public List<DiscountRegisterGroupRow> ByDate { get; set; } = new();
    public List<DiscountRegisterBillRow> Bills { get; set; } = new();
}

// ── Reports > LAB: generic result of the registered LAB report procedures ──
public class LabReportResult
{
    public Dictionary<string, object?> Summary { get; set; } = new();
    public List<Dictionary<string, object?>> Groups { get; set; } = new();
    public List<Dictionary<string, object?>> Rows { get; set; } = new();
    public List<Dictionary<string, object?>> Options { get; set; } = new();
}
