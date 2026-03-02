namespace EMR.Web.Models.Entities;

/// <summary>
/// One row per payment instrument used (supports split payments).
/// </summary>
public class PaymentDetail
{
    public int PaymentDetailId { get; set; }
    public int PaymentHeaderId { get; set; }
    public int PaymentMethodId { get; set; }
    public decimal PaidAmount { get; set; }

    // Method-specific fields
    public string? TransactionRef { get; set; }     // CARD / NEFT / WALLET UTR
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }           // UPI UTR or VPA
    public string? CardLast4 { get; set; }

    public DateTime PaymentDate { get; set; } = DateTime.UtcNow;
    public string? Notes { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? CreatedBy { get; set; }
    public bool IsActive { get; set; } = true;

    // Navigation
    public PaymentHeader? Header { get; set; }
    public PaymentMethodMaster? Method { get; set; }
}
