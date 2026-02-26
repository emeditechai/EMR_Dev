using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class CountryMaster
{
    public int CountryId { get; set; }

    [Required, MaxLength(20)]
    public string CountryCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string CountryName { get; set; } = string.Empty;

    [MaxLength(10)]
    public string? Currency { get; set; }

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<StateMaster> States { get; set; } = new List<StateMaster>();
}
