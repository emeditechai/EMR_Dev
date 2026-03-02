namespace EMR.Web.Models.Entities;

/// <summary>
/// One row per bill payment session.
/// ModuleCode: 'OPD' | 'IPD' | 'LAB' | 'MED'
/// ModuleRefId: module-specific PK (e.g. OPDServiceId for OPD).
/// OPDServiceId: explicit FK to PatientOPDService for OPD module convenience.
/// </summary>
public class PaymentHeader
{
    public int PaymentHeaderId { get; set; }

    // Module identification
    public string ModuleCode { get; set; } = string.Empty;  // OPD/IPD/LAB/MED
    public int ModuleRefId { get; set; }
    public int? OPDServiceId { get; set; }                  // FK to PatientOPDService

    public int BranchId { get; set; }
    public int PatientId { get; set; }

    // Financial — gross
    public decimal SubTotal { get; set; }

    // Line-item discount aggregate (sum of PaymentLineItem.LineDiscountAmount)
    public decimal LineDiscountTotal { get; set; }

    // Header-level (overall) discount
    public char? HeaderDiscountType { get; set; }           // 'P' = %, 'F' = fixed
    public decimal? HeaderDiscountValue { get; set; }       // value as entered
    public decimal HeaderDiscountAmount { get; set; }       // computed Rs amount

    // Final
    public decimal NetAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public char PaymentStatus { get; set; } = 'U';          // P=Paid, R=Partial, U=Unpaid

    public string? Notes { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? CreatedBy { get; set; }
    public DateTime? LastModifiedDate { get; set; }
    public int? LastModifiedBy { get; set; }
    public bool IsActive { get; set; } = true;

    // Navigation
    public PatientOPDService? OPDService { get; set; }
    public List<PaymentLineItem> LineItems { get; set; } = [];
    public List<PaymentDetail> Details { get; set; } = [];
}
