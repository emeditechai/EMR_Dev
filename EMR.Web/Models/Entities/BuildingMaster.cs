using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class BuildingMaster
{
    public int BuildingId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int? BranchId { get; set; }

    [Required, StringLength(4, MinimumLength = 4)]
    public string BuildingCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string BuildingName { get; set; } = string.Empty;

    [MaxLength(500)]
    public string? Description { get; set; }

    public int NumberOfFloors { get; set; } = 1;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigations
    public ICollection<FloorMaster> Floors { get; set; } = new List<FloorMaster>();
}
