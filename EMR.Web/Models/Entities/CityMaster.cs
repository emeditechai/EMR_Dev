using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class CityMaster
{
    public int CityId { get; set; }

    [Required, MaxLength(20)]
    public string CityCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string CityName { get; set; } = string.Empty;

    public int DistrictId { get; set; }
    public DistrictMaster? District { get; set; }

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<AreaMaster> Areas { get; set; } = new List<AreaMaster>();
}
