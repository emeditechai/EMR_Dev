using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class DistrictMaster
{
    public int DistrictId { get; set; }

    [Required, MaxLength(20)]
    public string DistrictCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string DistrictName { get; set; } = string.Empty;

    public int StateId { get; set; }
    public StateMaster? State { get; set; }

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<CityMaster> Cities { get; set; } = new List<CityMaster>();
}
