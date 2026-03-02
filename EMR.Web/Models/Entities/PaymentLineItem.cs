namespace EMR.Web.Models.Entities;

/// <summary>
/// One row per service/charge line on a bill.
/// ModuleLineRefId: OPD → PatientOPDServiceItem.ItemId; future modules use their own keys.
/// Phase 1: LineDiscountType/Value/Amount are null/0 (header-level discount only).
/// Phase 2: UI can edit per-line discounts.
/// </summary>
public class PaymentLineItem
{
    public int PaymentLineItemId { get; set; }
    public int PaymentHeaderId { get; set; }
    public int ModuleLineRefId { get; set; }    // e.g. PatientOPDServiceItem.ItemId
    public string? ItemDescription { get; set; }
    public string? ServiceType { get; set; }    // snapshot: Consulting / Service
    public decimal OriginalAmount { get; set; }

    // Per-line discount (null = none applied)
    public char? LineDiscountType { get; set; }     // 'P' = %, 'F' = fixed
    public decimal? LineDiscountValue { get; set; }
    public decimal LineDiscountAmount { get; set; }
    public decimal NetLineAmount { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? CreatedBy { get; set; }
    public bool IsActive { get; set; } = true;

    // Navigation
    public PaymentHeader? Header { get; set; }
}
