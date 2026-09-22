namespace EMR.Web.ApiClients.Models;

public class DailyCollectionRegisterItem
{
    public int PaymentHeaderId { get; set; }
    public string OPDBillNo { get; set; } = string.Empty;
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public DateTime PaymentDate { get; set; }
    
    public decimal TotalAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public string? PaymentStatus { get; set; }
    public string? PaymentModes { get; set; }

    // Detailed Report (Item Wise) specific fields
    public string? ItemName { get; set; }
    public string? ServiceType { get; set; }
    public decimal ServiceCharges { get; set; }
    public decimal ItemDiscount { get; set; }
    public decimal GstPercentage { get; set; }
    public decimal ItemGstAmount { get; set; }
    public decimal ItemTotalAmount { get; set; }
    
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
