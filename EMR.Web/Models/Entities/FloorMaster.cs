using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

public class FloorMaster
{
    public int FloorId { get; set; }

    [Required, MaxLength(20)]
    public string FloorCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string FloorName { get; set; } = string.Empty;

    public int? BuildingId { get; set; }

    [NotMapped]
    public string? BuildingName { get; set; }

    [NotMapped]
    public string? BuildingCode { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public BuildingMaster? Building { get; set; }
}

