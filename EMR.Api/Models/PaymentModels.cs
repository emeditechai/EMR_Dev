namespace EMR.Api.Models;

// ── Payment Summary Result ────────────────────────────────────────────────────

public class PaymentSummaryResult
{
    public int    ModuleRefId   { get; set; }
    public string ModuleCode    { get; set; } = string.Empty;
    public int?   OPDServiceId  { get; set; }
    public string? OPDBillNo    { get; set; }
    public string? TokenNo      { get; set; }
    public int    PatientId     { get; set; }
    public string? PatientCode  { get; set; }
    public string? PatientName  { get; set; }
    public string? PatientPhone { get; set; }
    public int    BranchId      { get; set; }

    // Line breakdown
    public List<PaymentLineItem> Items { get; set; } = [];
    public decimal SubTotal { get; set; }

    // Existing payment info (for partial-payment top-up)
    public bool    HasExistingPayment       { get; set; }
    public int?    ExistingPaymentHeaderId  { get; set; }
    public decimal ExistingLineDiscountTotal    { get; set; }
    public char?   ExistingHeaderDiscountType   { get; set; }
    public decimal? ExistingHeaderDiscountValue { get; set; }
    public decimal ExistingHeaderDiscountAmount { get; set; }
    public decimal NetAmount    { get; set; }
    public decimal TotalPaid    { get; set; }
    public decimal BalanceDue   { get; set; }
    public string  PaymentStatus { get; set; } = "U";
}

public class PaymentLineItem
{
    public int     LineRefId           { get; set; }
    public string? ServiceType         { get; set; }
    public string? ItemName            { get; set; }
    public decimal OriginalAmount      { get; set; }
    public decimal LineDiscountAmount  { get; set; }
    public decimal NetLineAmount       { get; set; }
}
