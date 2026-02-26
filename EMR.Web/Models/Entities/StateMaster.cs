using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class StateMaster
{
    public int StateId { get; set; }

    [Required, MaxLength(20)]
    public string StateCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string StateName { get; set; } = string.Empty;

    public int CountryId { get; set; }
    public CountryMaster? Country { get; set; }

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<DistrictMaster> Districts { get; set; } = new List<DistrictMaster>();
}
