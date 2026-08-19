using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("BedRoomTariffHistory", Schema = "dbo")]
public class BedRoomTariffHistory
{
    [Key]
    public int HistoryId { get; set; }

    [Required]
    public int BedRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required]
    public int WardId { get; set; }

    [Required]
    public int RoomId { get; set; }

    [Required]
    public int BedCategoryId { get; set; }

    [Required]
    public int TariffCategoryId { get; set; }

    [Required]
    public DateTime EffectiveFrom { get; set; }

    public DateTime? EffectiveTo { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal RoomCharge { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal BedCharge { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal NursingCharge { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal AttendantCharge { get; set; }

    [Column(TypeName = "decimal(18,2)")]
    public decimal IsolationCharge { get; set; }

    [Column(TypeName = "decimal(5,2)")]
    public decimal GstPercentage { get; set; }

    public bool IsActive { get; set; }

    [Required, MaxLength(50)]
    public string ChangeAction { get; set; } = "UPDATED";

    [MaxLength(500)]
    public string? ChangeReason { get; set; }

    public int? ChangedBy { get; set; }
    public string? ChangedByName { get; set; }

    public DateTime ChangedDate { get; set; } = DateTime.Now;

    public decimal TotalBaseCharge => RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge;
    public decimal TotalGstAmount => Math.Round(TotalBaseCharge * (GstPercentage / 100m), 2);
    public decimal TotalGrossAmount => TotalBaseCharge + TotalGstAmount;

    // Navigations
    public BedRoomTariffMaster? BedRate { get; set; }
}
