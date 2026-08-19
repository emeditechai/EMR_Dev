using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("BedRoomTariffMaster", Schema = "dbo")]
public class BedRoomTariffMaster
{
    [Key]
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
    public decimal RoomCharge { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal BedCharge { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal NursingCharge { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal AttendantCharge { get; set; } = 0;

    [Column(TypeName = "decimal(18,2)")]
    public decimal IsolationCharge { get; set; } = 0;

    [Column(TypeName = "decimal(5,2)")]
    public decimal GstPercentage { get; set; } = 0;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    public string? WardName { get; set; }
    public string? WardCode { get; set; }
    public string? RoomNumber { get; set; }
    public string? RoomType { get; set; }
    public string? BedCategoryName { get; set; }
    public string? BedCategoryCode { get; set; }
    public string? TariffCategoryName { get; set; }
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public string? BranchName { get; set; }

    // Computed helper properties
    public decimal TotalBaseCharge => RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge;
    public decimal TotalGstAmount => Math.Round(TotalBaseCharge * (GstPercentage / 100m), 2);
    public decimal TotalGrossAmount => TotalBaseCharge + TotalGstAmount;

    // Navigations
    public WardMaster? Ward { get; set; }
    public RoomMaster? Room { get; set; }
    public BedCategoryMaster? BedCategory { get; set; }
    public TariffCategoryMaster? TariffCategory { get; set; }
}
