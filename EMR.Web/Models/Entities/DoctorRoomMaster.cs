using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class DoctorRoomMaster
{
    public int RoomId { get; set; }

    [Required, MaxLength(10)]
    public string RoomName { get; set; } = string.Empty;

    public int FloorId { get; set; }
    public string? FloorName { get; set; }

    public int BranchId { get; set; }
    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
