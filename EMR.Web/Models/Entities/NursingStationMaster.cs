using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("NursingStationMaster", Schema = "dbo")]
public class NursingStationMaster
{
    [Key]
    public int NursingStationId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int WardId { get; set; }

    [Required, MaxLength(50)]
    public string StationCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string StationName { get; set; } = string.Empty;

    [MaxLength(150)]
    public string? ResponsibleNurse { get; set; }

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    public string? WardName { get; set; }
    public string? WardCode { get; set; }
    public string? WardType { get; set; }
    public string? FloorName { get; set; }

    // Navigations
    public WardMaster? Ward { get; set; }
}
