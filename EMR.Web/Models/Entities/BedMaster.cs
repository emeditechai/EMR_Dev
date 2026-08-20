using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("BedMaster", Schema = "dbo")]
public class BedMaster
{
    [Key]
    public int BedId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int BuildingId { get; set; }

    [Required]
    public int WardId { get; set; }

    [Required]
    public int RoomId { get; set; }

    [Required, MaxLength(50)]
    public string BedNumber { get; set; } = string.Empty;

    [Required]
    public int BedCategoryId { get; set; }

    [Required, MaxLength(30)]
    public string BedStatus { get; set; } = "Available";

    public bool IsIsolation { get; set; } = false;

    public bool IsICU { get; set; } = false;

    public bool IsVentilatorCapable { get; set; } = false;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    [NotMapped]
    public string? BuildingName { get; set; }
    [NotMapped]
    public string? BuildingCode { get; set; }
    [NotMapped]
    public string? WardName { get; set; }
    [NotMapped]
    public string? WardCode { get; set; }
    [NotMapped]
    public string? WardType { get; set; }
    [NotMapped]
    public string? RoomNumber { get; set; }
    [NotMapped]
    public string? RoomType { get; set; }
    [NotMapped]
    public string? FloorName { get; set; }
    [NotMapped]
    public string? BedCategoryName { get; set; }
    [NotMapped]
    public string? BedCategoryCode { get; set; }

    // Navigations
    public BuildingMaster? Building { get; set; }
    public WardMaster? Ward { get; set; }
    public RoomMaster? Room { get; set; }
    public BedCategoryMaster? BedCategory { get; set; }
}
