namespace EMR.Web.Models.ViewModels;

// ── Payment Method ────────────────────────────────────────────────────────────

public class PaymentMethodViewModel
{
    public int PaymentMethodId { get; set; }
    public string MethodName { get; set; } = string.Empty;
    public string MethodCode { get; set; } = string.Empty;
    public bool RequiresRef { get; set; }
    public bool RequiresChequeNo { get; set; }
    public bool RequiresBankName { get; set; }
    public bool RequiresUPIRef { get; set; }
    public bool RequiresCardLast4 { get; set; }
}

// ── Payment Summary (result of GetPaymentSummary) ─────────────────────────────

public class PaymentSummaryViewModel
{
    public int ModuleRefId { get; set; }
    public string ModuleCode { get; set; } = string.Empty;
    public int? OPDServiceId { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public string? PatientPhone { get; set; }
    public int BranchId { get; set; }

    // Line breakdown
    public List<PaymentLineItemSummary> Items { get; set; } = [];
    public decimal SubTotal { get; set; }   // sum of OriginalAmount

    // Existing payment (for partial-payment top-up)
    public bool HasExistingPayment { get; set; }
    public int? ExistingPaymentHeaderId { get; set; }
    public decimal ExistingLineDiscountTotal { get; set; }
    public char? ExistingHeaderDiscountType { get; set; }
    public decimal? ExistingHeaderDiscountValue { get; set; }
    public decimal ExistingHeaderDiscountAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";
}

public class PaymentLineItemSummary
{
    public int LineRefId { get; set; }          // ModuleLineRefId (e.g. ItemId)
    public string? ServiceType { get; set; }
    public string? ItemName { get; set; }
    public decimal OriginalAmount { get; set; }

    // Existing per-line discount (populated when HasExistingPayment = true)
    public char? LineDiscountType { get; set; }
    public decimal? LineDiscountValue { get; set; }
    public decimal LineDiscountAmount { get; set; }
    public decimal NetLineAmount { get; set; }
}

// ── Save Payment Request ──────────────────────────────────────────────────────

public class SavePaymentRequest
{
    public string ModuleCode { get; set; } = string.Empty;  // OPD/IPD/LAB/MED
    public int ModuleRefId { get; set; }
    public int? OPDServiceId { get; set; }
    public int PatientId { get; set; }
    public int BranchId { get; set; }
    public decimal SubTotal { get; set; }

    // Header-level discount
    public string? HeaderDiscountType { get; set; }         // "P" or "F"
    public decimal HeaderDiscountValue { get; set; }
    public decimal HeaderDiscountAmount { get; set; }

    public decimal NetAmount { get; set; }
    public string? Notes { get; set; }

    // Payment method(s) used
    public List<PaymentDetailRow> Payments { get; set; } = [];

    // Line items (sent from client for snapshot + future line-level discount)
    public List<PaymentLineItemRow> LineItems { get; set; } = [];
}

public class PaymentDetailRow
{
    public int PaymentMethodId { get; set; }
    public decimal PaidAmount { get; set; }
    public string? TransactionRef { get; set; }
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }
    public string? CardLast4 { get; set; }
    public string? Notes { get; set; }
}

public class PaymentLineItemRow
{
    public int ModuleLineRefId { get; set; }
    public string? ItemDescription { get; set; }
    public string? ServiceType { get; set; }
    public decimal OriginalAmount { get; set; }

    // Phase 1: nulls/0 — header discount only
    // Phase 2: UI sets these for per-line discounts
    public string? LineDiscountType { get; set; }           // "P" or "F"
    public decimal LineDiscountValue { get; set; }
    public decimal LineDiscountAmount { get; set; }
    public decimal NetLineAmount { get; set; }
}

// ── Bill Payment Summary (for PrintBill view) ───────────────────────────────

public class BillPaymentRow
{
    public string MethodName { get; set; } = string.Empty;
    public decimal PaidAmount { get; set; }
    public string? TransactionRef { get; set; }
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }
    public string? CardLast4 { get; set; }
}

public class BillPaymentSummary
{
    public decimal SubTotal { get; set; }
    public string? DiscountType { get; set; }        // "P" = percent, "F" = flat, null = none
    public decimal DiscountValue { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";  // P=Paid R=Partial U=Unpaid
    public DateTime? PaidOn { get; set; }
    public List<BillPaymentRow> Rows { get; set; } = [];
}

// ── Save Payment Result ───────────────────────────────────────────────────────

public class SavePaymentResult
{
    public bool Success { get; set; }
    public string? Error { get; set; }
    public int? PaymentHeaderId { get; set; }
    public decimal NetAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";
}
