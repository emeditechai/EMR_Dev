using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class MaritalStatusMaster
{
    public int MaritalStatusId { get; set; }

    [Required, MaxLength(50)]
    public string StatusName { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
