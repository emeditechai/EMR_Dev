using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorBillingAdjustment", Schema = "dbo")]
public class DoctorBillingAdjustment
{
    [Key]
    public int AdjustmentId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; } = 1;

    public int? DisbursalId { get; set; }

    public int VisitId { get; set; }

    public int? BillId { get; set; }

    public int DoctorId { get; set; }

    [Required, MaxLength(50)]
    public string AdjustmentType { get; set; } = string.Empty;

    [Column(TypeName = "decimal(18,2)")]
    public decimal Amount { get; set; }

    [Required, MaxLength(500)]
    public string Reason { get; set; } = string.Empty;

    public int? RequestedBy { get; set; }

    public int? ApprovedBy { get; set; }

    public DateTime AdjustmentDate { get; set; } = DateTime.Now;

    public bool IsActive { get; set; } = true;
}
