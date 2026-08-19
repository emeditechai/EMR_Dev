using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("WardMaster", Schema = "dbo")]
public class WardMaster
{
    [Key]
    public int WardId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required]
    public int FloorId { get; set; }

    [Required]
    public int DepartmentId { get; set; }

    [Required, MaxLength(5)]
    public string WardCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string WardName { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string WardType { get; set; } = "General Ward";

    [Required, MaxLength(20)]
    public string Gender { get; set; } = "Unisex / All";

    public int Capacity { get; set; } = 1;

    public bool IsIsolationWard { get; set; } = false;

    [MaxLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Join helper fields
    public string? FloorName { get; set; }
    public string? FloorCode { get; set; }
    public string? BuildingName { get; set; }
    public string? DepartmentName { get; set; }
    public string? DepartmentCode { get; set; }

    // Navigations
    public FloorMaster? Floor { get; set; }
    public DepartmentMaster? Department { get; set; }
    public ICollection<NursingStationMaster> NursingStations { get; set; } = new List<NursingStationMaster>();
}
