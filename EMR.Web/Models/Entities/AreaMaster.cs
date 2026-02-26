using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class AreaMaster
{
    public int AreaId { get; set; }

    [Required, MaxLength(20)]
    public string AreaCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string AreaName { get; set; } = string.Empty;

    public int CityId { get; set; }
    public CityMaster? City { get; set; }

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
