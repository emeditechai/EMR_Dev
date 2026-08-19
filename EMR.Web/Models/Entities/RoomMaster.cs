using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("RoomMaster", Schema = "dbo")]
public class RoomMaster
{
    [Key]
    public int RoomId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int BuildingId { get; set; }

    [Required]
    public int FloorId { get; set; }

    [Required]
    public int WardId { get; set; }

    [Required, MaxLength(50)]
    public string RoomNumber { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string RoomType { get; set; } = "Single Room";

    [Required, MaxLength(50)]
    public string RoomCategory { get; set; } = "General";

    public bool IsIsolation { get; set; } = false;

    public int BedCapacity { get; set; } = 1;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    public string? BuildingName { get; set; }
    public string? BuildingCode { get; set; }
    public string? FloorName { get; set; }
    public string? FloorCode { get; set; }
    public string? WardName { get; set; }
    public string? WardCode { get; set; }
    public string? WardType { get; set; }

    // Navigations
    public BuildingMaster? Building { get; set; }
    public FloorMaster? Floor { get; set; }
    public WardMaster? Ward { get; set; }
}
