using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorDisbursal", Schema = "dbo")]
public class DoctorDisbursal
{
    [Key]
    public int DisbursalId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; } = 1;

    public int DoctorId { get; set; }

    public int VisitId { get; set; }

    public int? BillId { get; set; }

    public int? ConsultationId { get; set; }

    [Required, MaxLength(50)]
    public string RevenueType { get; set; } = "Consultation";

    [Column(TypeName = "decimal(18,2)")]
    public decimal GrossBillAmount { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal DiscountAmount { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal ApprovedAdjustment { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal NetBillAmount { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal CollectedAmount { get; set; }

    [Required, MaxLength(50)]
    public string CommissionBasis { get; set; } = "Net Collected";

    [Column(TypeName = "decimal(18,2)")]
    public decimal EligibleAmount { get; set; }

    public int? CommissionConfigId { get; set; }

    [Required, MaxLength(200)]
    public string CommissionRule { get; set; } = string.Empty;

    [Column(TypeName = "decimal(18,2)")]
    public decimal? CommissionPercentage { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal CalculatedAmount { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal AdjustmentAmount { get; set; }

    [MaxLength(500)]
    public string? AdjustmentReason { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal NetPayable { get; set; }

    [Required, MaxLength(20)]
    public string SettlementPeriod { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string ApprovalStatus { get; set; } = "CALCULATED";

    [Required, MaxLength(50)]
    public string PaymentStatus { get; set; } = "Pending";

    public int? ApprovedBy { get; set; }

    public DateTime? ApprovedDate { get; set; }

    [MaxLength(50)]
    public string? PaymentMethod { get; set; }

    [MaxLength(100)]
    public string? PaymentReference { get; set; }

    public DateTime? PaidDate { get; set; }

    public int? PaidBy { get; set; }

    public string? DisbursalNotes { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? CreatedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    public int? ModifiedBy { get; set; }
}
