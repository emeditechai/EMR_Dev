using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class FloorMaster
{
    public int FloorId { get; set; }

    [Required, MaxLength(20)]
    public string FloorCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string FloorName { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
